defmodule VeraWeb.AccountLive.ApiTokens do
  use VeraWeb, :live_view

  alias Vera.Accounts
  alias Vera.Accounts.AccountToken

  def mount(_params, _session, socket) do
    account = socket.assigns.current_account
    tokens = list_account_tokens(account)
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "accounts/#{account.id}/tokens")

    {:ok,
     socket
     |> stream(:tokens, tokens)
     |> assign(:new_token, nil)}
  end

  defp list_account_tokens(account) do
    AccountToken.by_account_and_contexts_query(account, ["api-token"])
    |> Vera.Repo.all()
  end

  def handle_info({:token_created, token}, socket) do
    tokens = list_account_tokens(socket.assigns.current_account)
    {:noreply,
     socket
     |> assign(:new_token, token)
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
    account = socket.assigns.current_account
    token = Accounts.create_account_api_token(account)
    Phoenix.PubSub.broadcast(Vera.PubSub, "accounts/#{socket.assigns.current_account.id}/tokens", {:token_created, token})
    {:noreply, socket}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    {id, _} = Integer.parse(token_id)
    token = Vera.Repo.get!(AccountToken, id)
    {:ok, _} = Vera.Repo.delete(token)
    Phoenix.PubSub.broadcast(Vera.PubSub, "accounts/#{socket.assigns.current_account.id}/tokens", {:token_deleted, token})
    {:noreply, socket}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end
end
