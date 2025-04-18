defmodule VeraWeb.AccountLive.ApiTokens do
  use VeraWeb, :live_view

  alias Vera.Accounts
  alias Vera.Accounts.AccountToken

  def mount(_params, _session, socket) do
    account = socket.assigns.current_account
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "accounts/#{account.id}/tokens")

    # The context is "api-token" in your AccountToken module, not "api_token"
    tokens = list_account_tokens(account)

    {:ok,
     socket
     |> stream(:tokens, tokens)
     |> assign(:new_token, nil)}
  end

  def handle_event("create_token", _params, socket) do
    account = socket.assigns.current_account
    token = Accounts.create_account_api_token(account)
    Phoenix.PubSub.broadcast(
      Vera.PubSub,
      "accounts/#{account.id}/tokens",
      {:token_created, token, "API token created."}
    )
    tokens = list_account_tokens(account)
    {:noreply,
     socket
     |> stream(:tokens, tokens, reset: true)
     |> assign(:new_token, token)}
  end

  def handle_event("delete_token", %{"id" => token_id}, socket) do
    {id, _} = Integer.parse(token_id)
    token = Vera.Repo.get!(AccountToken, id)
    {:ok, _} = Vera.Repo.delete(token)
    Phoenix.PubSub.broadcast(
      Vera.PubSub,
      "accounts/#{socket.assigns.current_account.id}/tokens",
      {:token_deleted, token, "API token deleted."}
    )
    {:noreply,
     socket
     |> stream_delete(:tokens, token)}
  end
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  def handle_info({:token_created, _token, message}, socket) do
    tokens = list_account_tokens(socket.assigns.current_account)
    {:noreply,
     socket
     |> stream(:tokens, tokens, reset: true)
     |> put_flash(:info, message)}
  end

  def handle_info({:token_deleted, token, message}, socket) do
    {:noreply,
     socket
     |> stream_delete(:tokens, token)
     |> put_flash(:info, message)}
  end

  defp list_account_tokens(account) do
    AccountToken.by_account_and_contexts_query(account, ["api-token"])
    |> Vera.Repo.all()
  end
end
