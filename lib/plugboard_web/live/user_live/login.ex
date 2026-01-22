defmodule PlugboardWeb.UserLive.Login do
  use PlugboardWeb, :live_view

  alias Plugboard.Accounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="flex items-center justify-center min-h-[calc(100vh-8rem)]">
        <div class="mx-auto max-w-sm space-y-4 w-full">
          <div class="text-center">
            <.header>
              <p class="ui-text-primary">Log in</p>
              <:subtitle>
                <%= if @current_scope do %>
                  <span class="ui-text-secondary">
                    You need to reauthenticate to perform sensitive actions on your account.
                  </span>
                <% else %>
                  <span class="ui-text-secondary">
                    Don't have an account? <.link
                      navigate={~p"/users/register"}
                      class="font-semibold ui-text-primary hover:underline"
                      phx-no-format
                    >Sign up</.link> for an account now.
                  </span>
                <% end %>
              </:subtitle>
            </.header>
          </div>

          <div
            :if={local_mail_adapter?()}
            class="ui-inverted-background rounded-2xl p-5 flex gap-3"
          >
            <.icon name="hero-information-circle" class="size-6 shrink-0 ui-inverted-text-primary" />
            <div>
              <p class="ui-inverted-text-primary">You are running the local mail adapter.</p>

              <p class="ui-inverted-text-secondary">
                To see sent emails, visit <.link
                  href="/dev/mailbox"
                  class="underline ui-inverted-text-primary hover:ui-inverted-text-secondary"
                >the mailbox page</.link>.
              </p>
            </div>
          </div>
          <.form
            :let={f}
            for={@form}
            id="login_form_password"
            action={~p"/users/log-in"}
            phx-submit="submit_password"
            phx-trigger-action={@trigger_submit}
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              label_class="ui-text-primary text-sm"
              autocomplete="username"
              required
            />
            <.input
              field={@form[:password]}
              type="password"
              label="Password"
              label_class="ui-text-primary text-sm"
              autocomplete="current-password"
            />
            <.button type="submit" name={@form[:remember_me].name} value="true">
              ● Log in with password
            </.button>
            <%!-- <.button type="submit" class="mt-2">
            ● Log in only this time
          </.button> --%>
          </.form>
          <div class="divider">or</div>
          <.form
            :let={f}
            for={@form}
            id="login_form_magic"
            action={~p"/users/log-in"}
            phx-submit="submit_magic"
          >
            <.input
              readonly={!!@current_scope}
              field={f[:email]}
              type="email"
              label="Email"
              label_class="ui-text-primary text-sm"
              autocomplete="username"
              required
              phx-mounted={JS.focus()}
            />
            <.button type="submit">
              ● Log in with email OTP
            </.button>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    email =
      Phoenix.Flash.get(socket.assigns.flash, :email) ||
        get_in(socket.assigns, [:current_scope, Access.key(:user), Access.key(:email)])

    form = to_form(%{"email" => email}, as: "user")

    {:ok, assign(socket, form: form, trigger_submit: false)}
  end

  @impl true
  def handle_event("submit_password", _params, socket) do
    {:noreply, assign(socket, :trigger_submit, true)}
  end

  def handle_event("submit_magic", %{"user" => %{"email" => email}}, socket) do
    if user = Accounts.get_user_by_email(email) do
      Accounts.deliver_login_instructions(
        user,
        &url(~p"/users/log-in/#{&1}")
      )
    end

    info =
      "If your email is in our system, you will receive instructions for logging in shortly."

    {:noreply,
     socket
     |> put_flash(:info, info)
     |> push_navigate(to: ~p"/users/log-in")}
  end

  defp local_mail_adapter? do
    Application.get_env(:plugboard, Plugboard.Mailer)[:adapter] == Swoosh.Adapters.Local
  end
end
