defmodule PlugboardWeb.AccountLive.Show do
  use PlugboardWeb, :live_view
  alias Phoenix.PubSub
  alias Plugboard.Accounts.Accounts
  alias Plugboard.Accounts.AccountToken

  def mount(%{"id" => id}, _session, socket) do
    account = Accounts.get_account!(id)
    tokens = list_account_tokens(account)
    if connected?(socket), do: PubSub.subscribe(Plugboard.PubSub, "accounts/#{account.id}/tokens")

    {:ok,
     socket
     |> assign(:account, account)
     |> stream(:tokens, tokens)
     |> assign(:new_token, nil)
     |> assign(:page_title, "Account - #{account.email}")}
  end

  defp list_account_tokens(account) do
    AccountToken.by_account_and_contexts_query(account, ["api-token"])
    |> Plugboard.Repo.all()
  end

  def handle_info({:token_created, token}, socket) do
    tokens = list_account_tokens(socket.assigns.account)

    {:noreply,
     socket
     |> assign(:new_token, token.value)
     |> stream(:tokens, tokens, reset: true)
     |> put_flash(:info, "API token created")}
  end

  def handle_info({:token_deleted, token}, socket) do
    {:noreply,
     socket
     |> stream_delete(:tokens, token)
     |> put_flash(:info, "API token deleted")}
  end

  def handle_event("create_token", _params, socket) do
    account = socket.assigns.account
    token = Accounts.create_account_api_token(account)

    PubSub.broadcast(
      Plugboard.PubSub,
      "accounts/#{account.id}/tokens",
      {:token_created, token}
    )

    {:noreply, socket}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    {id, _} = Integer.parse(token_id)
    token = Plugboard.Repo.get!(AccountToken, id)
    {:ok, _} = Plugboard.Repo.delete(token)

    PubSub.broadcast(
      Plugboard.PubSub,
      "accounts/#{socket.assigns.account.id}/tokens",
      {:token_deleted, token}
    )

    {:noreply, socket}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  def handle_event("delete_account", _params, socket) do
    case Accounts.delete_account(socket.assigns.account) do
      {:ok, _account} ->
        {:noreply,
         socket
         |> put_flash(:info, "Account deleted successfully")
         |> push_navigate(to: ~p"/accounts")}

      {:error, _changeset} ->
        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete account")
         |> push_navigate(to: ~p"/accounts")}
    end
  end
end
