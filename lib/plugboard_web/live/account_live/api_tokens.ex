defmodule PlugboardWeb.AccountLive.ApiTokens do
  use PlugboardWeb, :live_view
  alias Phoenix.PubSub
  alias Plugboard.Accounts.Accounts
  alias Plugboard.Accounts.AccountToken

  def mount(_params, _session, socket) do
    account = socket.assigns.current_account
    tokens = list_account_tokens(account)
    if connected?(socket), do: PubSub.subscribe(Plugboard.PubSub, "accounts/#{account.id}/tokens")

    {:ok,
     socket
     |> stream(:tokens, tokens)
     |> assign(:new_token, nil)
     |> assign(:page_title, page_title(socket.assigns.live_action))}
  end

  defp list_account_tokens(account) do
    AccountToken.by_account_and_contexts_query(account, ["api-token"])
    |> Plugboard.Repo.all()
  end

  def handle_info({:token_created, token}, socket) do
    tokens = list_account_tokens(socket.assigns.current_account)
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
    account = socket.assigns.current_account
    token = Accounts.create_account_api_token(account)
    PubSub.broadcast(Plugboard.PubSub, "accounts/#{socket.assigns.current_account.id}/tokens", {:token_created, token})
    {:noreply, socket}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    {id, _} = Integer.parse(token_id)
    token = Plugboard.Repo.get!(AccountToken, id)
    {:ok, _} = Plugboard.Repo.delete(token)
    PubSub.broadcast(Plugboard.PubSub, "accounts/#{socket.assigns.current_account.id}/tokens", {:token_deleted, token})
    {:noreply, socket}
  end

  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  defp page_title(:index), do: "Plugboard | Account API Tokens"
end
