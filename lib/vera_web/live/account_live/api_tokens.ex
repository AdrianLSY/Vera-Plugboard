defmodule VeraWeb.AccountLive.ApiTokens do
  use VeraWeb, :live_view

  alias Vera.Accounts
  alias Vera.Accounts.AccountToken

  @impl true
  def mount(_params, _session, socket) do
    account = socket.assigns.current_account
    if connected?(socket), do: Phoenix.PubSub.subscribe(Vera.PubSub, "accounts/#{account.id}/api_tokens")

    # The context is "api-token" in your AccountToken module, not "api_token"
    tokens = list_account_tokens(account)

    {:ok,
     socket
     |> stream(:tokens, tokens)
     |> assign(:new_token, nil)}
  end

  @impl true
  def handle_event("create_token", _params, socket) do
    account = socket.assigns.current_account
    token = Accounts.create_account_api_token(account)

    # Get the updated list of tokens
    tokens = list_account_tokens(account)

    {:noreply,
     socket
     |> stream(:tokens, tokens, reset: true)
     |> assign(:new_token, token)}
  end

  @impl true
  def handle_event("delete_token", %{"id" => token_id}, socket) do
    # Convert string ID to integer
    {id, _} = Integer.parse(token_id)

    # Find and delete the token
    token = Vera.Repo.get!(AccountToken, id)
    {:ok, _} = Vera.Repo.delete(token)

    {:noreply,
     socket
     |> put_flash(:info, "API token deleted successfully.")
     |> stream_delete(:tokens, token)}
  end

  @impl true
  def handle_event("dismiss_token", _params, socket) do
    {:noreply, assign(socket, :new_token, nil)}
  end

  defp list_account_tokens(account) do
    AccountToken.by_account_and_contexts_query(account, ["api-token"])
    |> Vera.Repo.all()
  end
end
