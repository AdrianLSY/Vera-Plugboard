defmodule VeraWeb.AccountLive.Login do
  use VeraWeb, :live_view

  def render(assigns) do
    ~H"""
    <div class="mx-auto max-w-2xl shadow-zinc-700/10 ring-zinc-700/10 relative rounded-xl bg-white p-14 shadow-lg ring-1">
      <.header>
        Log in to account
        <:subtitle>
          Don't have an account?
          <.link navigate={~p"/accounts/register"} class="font-semibold text-brand hover:underline">
            Sign up
          </.link>
          for an account now.
        </:subtitle>
      </.header>

      <.simple_form for={@form} id="login_form" action={~p"/accounts/log_in"} phx-update="ignore">
        <.input field={@form[:email]} type="email" label="Email" required />
        <.input field={@form[:password]} type="password" label="Password" required />

        <:actions>
          <.input field={@form[:remember_me]} type="checkbox" label="Keep me logged in" />
          <.link href={~p"/accounts/reset_password"} class="text-sm text-brand hover:underline">
            Forgot your password?
          </.link>
        </:actions>
        <:actions>
          <.button phx-disable-with="Logging in..." class="w-full">
            Log in
          </.button>
        </:actions>
      </.simple_form>
    </div>
    """
  end

  def mount(_params, _session, socket) do
    email = Phoenix.Flash.get(socket.assigns.flash, :email)
    form = to_form(%{"email" => email, "remember_me" => true}, as: "account")
    {:ok, assign(socket, form: form), temporary_assigns: [form: form]}
  end
end
