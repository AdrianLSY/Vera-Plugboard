defmodule PlugboardWeb.PathTokensLive.Index do
  @moduledoc """
  LiveView for managing telephone tokens and service accounts for a specific path.
  """

  use PlugboardWeb, :live_view

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens
  alias Plugboard.ServiceAccounts

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <.header>
          <p class="ui-text-primary">Manage Tokens for {[@path.full_path]}</p>
          <:subtitle>
            <span class="ui-text-secondary">
              Create telephone tokens and service accounts for auto-scaling
            </span>
          </:subtitle>
          <:actions>
            <.link navigate={~p"/paths?parent=#{@path.parent_id}"} class="text-sm ui-text-secondary hover:ui-text-primary">
              ← Back to Paths
            </.link>
          </:actions>
        </.header>

        <!-- Tab Navigation -->
        <div class="mt-8 border-b border-ui-border">
          <div class="flex gap-4">
            <button
              phx-click="switch_tab"
              phx-value-tab="tokens"
              class={"px-4 py-2 -mb-px border-b-2 transition-colors " <>
                if @active_tab == "tokens" do
                  "border-ui-inverted-foreground ui-text-primary font-medium"
                else
                  "border-transparent ui-text-secondary hover:ui-text-primary"
                end}
            >
              Telephone Tokens
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="service_accounts"
              class={"px-4 py-2 -mb-px border-b-2 transition-colors " <>
                if @active_tab == "service_accounts" do
                  "border-ui-inverted-foreground ui-text-primary font-medium"
                else
                  "border-transparent ui-text-secondary hover:ui-text-primary"
                end}
            >
              Service Accounts
            </button>
          </div>
        </div>

        <!-- Telephone Tokens Tab -->
        <div :if={@active_tab == "tokens"} class="mt-8">
          <!-- Create Token Form -->
          <div class="mb-8 p-6 bg-[var(--ui-foreground)] rounded-lg">
            <h3 class="text-lg font-semibold ui-text-primary mb-4">Create New Token</h3>
            <.form for={@token_form} phx-submit="create_token" class="flex gap-4 items-end">
              <div class="flex-1">
                <label class="block text-sm ui-text-secondary mb-2">
                  Description (optional)
                </label>
                <input
                  type="text"
                  name="token[description]"
                  placeholder="e.g., Production server, Development instance"
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full"
                />
              </div>
              <.button
                type="submit"
                phx-disable-with="Creating..."
                class="!w-auto px-6"
              >
                ● Create Token
              </.button>
            </.form>
          </div>

          <!-- Token Created Modal -->
          <.pop_up_form
            :if={@created_token}
            id="token-created-modal"
            title="Token Created Successfully"
            title_align="left"
            on_cancel={JS.push("close_token_modal")}
          >
            <:form>
              <div class="space-y-4">
                <p class="ui-text-secondary text-sm">
                  ⚠️ Store this token securely. It cannot be retrieved again.
                </p>
                <div class="bg-[var(--ui-background)] p-4 rounded-lg">
                  <pre class="text-xs font-mono ui-text-primary overflow-x-auto whitespace-pre-wrap break-all">{@created_token}</pre>
                </div>
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:copy", to: "#token-value")}
                  class="interactive-button-base icon-button"
                >
                  <.icon name="hero-clipboard" class="icon-button-icon" />
                  Copy to Clipboard
                </button>
                <input
                  id="token-value"
                  type="hidden"
                  value={@created_token}
                  phx-hook="Copy"
                />
              </div>
            </:form>
          </.pop_up_form>

          <!-- Tokens List -->
          <div class="space-y-4">
            <h3 class="text-lg font-semibold ui-text-primary">Active Tokens</h3>
            <%= if @tokens == [] do %>
              <p class="ui-text-secondary">No tokens found. Create one to get started.</p>
            <% else %>
              <div class="space-y-2">
                <%= for token <- @tokens do %>
                  <div class="p-4 bg-[var(--ui-foreground)] rounded-lg flex items-center justify-between">
                    <div class="flex-1">
                      <p class="ui-text-primary font-medium">
                        {token.description || "Unnamed token"}
                      </p>
                      <div class="flex gap-4 text-sm ui-text-secondary mt-1">
                        <span>Created: {format_datetime(token.inserted_at)}</span>
                        <span>Expires: {format_datetime(token.expires_at)}</span>
                        <%= if token.last_used_at do %>
                          <span>Last used: {format_datetime(token.last_used_at)}</span>
                        <% else %>
                          <span>Never used</span>
                        <% end %>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="revoke_token"
                      phx-value-id={token.id}
                      data-confirm="Are you sure you want to revoke this token? This action cannot be undone."
                      class="interactive-button-base icon-button"
                      title="Revoke"
                    >
                      <.icon name="hero-trash" class="icon-button-icon" />
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>

        <!-- Service Accounts Tab -->
        <div :if={@active_tab == "service_accounts"} class="mt-8">
          <!-- Create Service Account Form -->
          <div class="mb-8 p-6 bg-[var(--ui-foreground)] rounded-lg">
            <h3 class="text-lg font-semibold ui-text-primary mb-4">Create New Service Account</h3>
            <.form for={@sa_form} phx-submit="create_service_account" class="space-y-4">
              <div>
                <label class="block text-sm ui-text-secondary mb-2">
                  Name (required)
                </label>
                <input
                  type="text"
                  name="service_account[name]"
                  placeholder="e.g., production-cluster, staging-env"
                  required
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full"
                />
                <p class="text-xs ui-text-secondary mt-1">
                  Use letters, numbers, hyphens, and underscores only
                </p>
              </div>
              <div>
                <label class="block text-sm ui-text-secondary mb-2">
                  Description (optional)
                </label>
                <input
                  type="text"
                  name="service_account[description]"
                  placeholder="e.g., Auto-scaling cluster for production workloads"
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-inverted-foreground rounded-full"
                />
              </div>
              <.button
                type="submit"
                phx-disable-with="Creating..."
                class="!w-auto px-6"
              >
                ● Create Service Account
              </.button>
            </.form>
          </div>

          <!-- Service Account Created Modal -->
          <.pop_up_form
            :if={@created_api_key}
            id="api-key-created-modal"
            title="Service Account Created Successfully"
            title_align="left"
            on_cancel={JS.push("close_api_key_modal")}
          >
            <:form>
              <div class="space-y-4">
                <p class="ui-text-secondary text-sm">
                  ⚠️ Store this API key securely. It cannot be retrieved again.
                </p>
                <div class="bg-[var(--ui-background)] p-4 rounded-lg">
                  <pre class="text-xs font-mono ui-text-primary overflow-x-auto whitespace-pre-wrap break-all">{@created_api_key}</pre>
                </div>
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:copy", to: "#api-key-value")}
                  class="interactive-button-base icon-button"
                >
                  <.icon name="hero-clipboard" class="icon-button-icon" />
                  Copy to Clipboard
                </button>
                <input
                  id="api-key-value"
                  type="hidden"
                  value={@created_api_key}
                  phx-hook="Copy"
                />
              </div>
            </:form>
          </.pop_up_form>

          <!-- Service Accounts List -->
          <div class="space-y-4">
            <h3 class="text-lg font-semibold ui-text-primary">Active Service Accounts</h3>
            <%= if @service_accounts == [] do %>
              <p class="ui-text-secondary">No service accounts found. Create one to enable auto-scaling.</p>
            <% else %>
              <div class="space-y-2">
                <%= for sa <- @service_accounts do %>
                  <div class="p-4 bg-[var(--ui-foreground)] rounded-lg flex items-center justify-between">
                    <div class="flex-1">
                      <p class="ui-text-primary font-medium">{sa.name}</p>
                      <%= if sa.description do %>
                        <p class="text-sm ui-text-secondary mt-1">{sa.description}</p>
                      <% end %>
                      <div class="flex gap-4 text-sm ui-text-secondary mt-1">
                        <span>Created: {format_datetime(sa.inserted_at)}</span>
                        <%= if sa.last_used_at do %>
                          <span>Last used: {format_datetime(sa.last_used_at)}</span>
                        <% else %>
                          <span>Never used</span>
                        <% end %>
                      </div>
                    </div>
                    <button
                      type="button"
                      phx-click="revoke_service_account"
                      phx-value-id={sa.id}
                      data-confirm="Are you sure you want to revoke this service account? This action cannot be undone."
                      class="interactive-button-base icon-button"
                      title="Revoke"
                    >
                      <.icon name="hero-trash" class="icon-button-icon" />
                    </button>
                  </div>
                <% end %>
              </div>
            <% end %>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"path_id" => path_id}, _session, socket) do
    user = socket.assigns.current_scope.user

    # Get the path and verify access
    case Paths.get_path(path_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Path not found")
         |> redirect(to: ~p"/paths")}

      path ->
        # Check user has access
        case Paths.get_user_role(user.id, path_id) do
          nil ->
            {:ok,
             socket
             |> put_flash(:error, "You do not have access to this path")
             |> redirect(to: ~p"/paths")}

          role ->
            # Load tokens and service accounts
            tokens = TelephoneTokens.list_tokens_for_path(path_id)
            service_accounts = ServiceAccounts.list_service_accounts_for_path(path_id)

            {:ok,
             assign(socket,
               path: path,
               user_role: role,
               active_tab: "tokens",
               tokens: tokens,
               service_accounts: service_accounts,
               token_form: to_form(%{}, as: "token"),
               sa_form: to_form(%{}, as: "service_account"),
               created_token: nil,
               created_api_key: nil
             )}
        end
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("create_token", %{"token" => %{"description" => description}}, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.path

    # Check if user has permission (owner or maintainer)
    if socket.assigns.user_role in ["owner", "maintainer"] do
      desc = if description == "", do: nil, else: description

      case TelephoneTokens.generate_token(path, user, desc) do
        {:ok, jwt, _token} ->
          # Reload tokens
          tokens = TelephoneTokens.list_tokens_for_path(path.id)

          {:noreply,
           socket
           |> assign(tokens: tokens, created_token: jwt)
           |> put_flash(:info, "Token created successfully")}

        {:error, reason} when is_binary(reason) ->
          {:noreply, put_flash(socket, :error, reason)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to create token")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("close_token_modal", _params, socket) do
    {:noreply, assign(socket, created_token: nil)}
  end

  @impl true
  def handle_event("revoke_token", %{"id" => token_id}, socket) do
    if socket.assigns.user_role in ["owner", "maintainer"] do
      case TelephoneTokens.revoke_token(token_id) do
        {:ok, _token} ->
          # Reload tokens
          tokens = TelephoneTokens.list_tokens_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(tokens: tokens)
           |> put_flash(:info, "Token revoked successfully")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to revoke token")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("create_service_account", params, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.path

    name = get_in(params, ["service_account", "name"])
    description = get_in(params, ["service_account", "description"])

    # Check if user has permission (owner or maintainer)
    if socket.assigns.user_role in ["owner", "maintainer"] do
      desc = if description == "", do: nil, else: description

      case ServiceAccounts.generate_service_account(user, path.id, name, desc) do
        {:ok, api_key, _sa} ->
          # Reload service accounts
          service_accounts = ServiceAccounts.list_service_accounts_for_path(path.id)

          {:noreply,
           socket
           |> assign(service_accounts: service_accounts, created_api_key: api_key)
           |> put_flash(:info, "Service account created successfully")}

        {:error, reason} when is_binary(reason) ->
          {:noreply, put_flash(socket, :error, reason)}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to create service account")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("close_api_key_modal", _params, socket) do
    {:noreply, assign(socket, created_api_key: nil)}
  end

  @impl true
  def handle_event("revoke_service_account", %{"id" => sa_id}, socket) do
    if socket.assigns.user_role in ["owner", "maintainer"] do
      case ServiceAccounts.revoke_service_account(sa_id) do
        {:ok, _sa} ->
          # Reload service accounts
          service_accounts = ServiceAccounts.list_service_accounts_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(service_accounts: service_accounts)
           |> put_flash(:info, "Service account revoked successfully")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to revoke service account")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end
end
