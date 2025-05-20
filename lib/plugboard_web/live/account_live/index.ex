defmodule PlugboardWeb.AccountLive.Index do
  use PlugboardWeb, :live_view

  alias Plugboard.Accounts.Accounts
  alias Plugboard.Accounts.Account

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Plugboard.PubSub, "accounts")

    socket =
      socket
      |> assign(:page_title, "Listing Accounts")
      |> stream(:accounts, Accounts.list_accounts())

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _url, socket) do
    {:noreply, apply_action(socket, socket.assigns.live_action, params)}
  end

  defp apply_action(socket, :edit, %{"id" => id}) do
    account = Accounts.get_account!(id)
    changeset = Accounts.change_account_registration(account)

    socket
    |> assign(:page_title, "Edit Account")
    |> assign(:account, account)
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :new, _params) do
    changeset = Accounts.change_account_registration(%Account{})

    socket
    |> assign(:page_title, "New Account")
    |> assign(:account, %Account{})
    |> assign(:form, to_form(changeset))
  end

  defp apply_action(socket, :index, _params) do
    socket
    |> assign(:account, nil)
    |> assign(:form, nil)
  end

  @impl true
  def handle_event("validate", %{"account" => account_params}, socket) do
    changeset =
      socket.assigns.account
      |> Accounts.change_account_registration(account_params)
      |> Map.put(:action, :validate)

    {:noreply, assign(socket, form: to_form(changeset))}
  end

  @impl true
  def handle_event("save", %{"account" => account_params}, socket) do
    save_account(socket, socket.assigns.live_action, account_params)
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    account = Accounts.get_account!(id)
    {:ok, _} = Accounts.delete_account(account)

    {:noreply, stream_delete(socket, :accounts, account)}
  end

  defp save_account(socket, :edit, account_params) do
    # For editing, we don't want to change the password unless explicitly provided
    account_params = Map.delete(account_params, "password")

    case Accounts.update_account_admin(socket.assigns.account, account_params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account updated successfully")
         |> push_navigate(to: ~p"/accounts")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_account(socket, :new, account_params) do
    case Accounts.register_account(account_params) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account created successfully")
         |> push_navigate(to: ~p"/accounts")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end
end
