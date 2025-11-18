defmodule PlugboardWeb.PathTokensLive.Index do
  @moduledoc """
  LiveView for managing telephone tokens and service accounts for a specific path.
  """

  use PlugboardWeb, :live_view

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens
  alias Plugboard.ServiceAccounts
  alias Plugboard.DomainAffinities
  alias Plugboard.Hooks

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div>
        <.header>
          <p class="ui-text-primary">Tokens</p>
          <:subtitle>
            <span class="ui-text-secondary">
              Create telephone tokens and service accounts for auto-scaling
            </span>
          </:subtitle>
        </.header>
        
    <!-- Breadcrumb Navigation -->
        <div class="mt-8">
          <div class="bg-[var(--ui-foreground)] rounded-full px-4 py-2 overflow-x-auto max-w-full inline-block">
            <div class="flex items-center gap-2 text-sm ui-text-secondary whitespace-nowrap">
              <.link
                navigate={~p"/paths"}
                class="hover:ui-text-primary transition-colors"
                data-test="breadcrumb-root"
              >
                Root
              </.link>
              <%= for {breadcrumb, index} <- Enum.with_index(@breadcrumbs) do %>
                <span>/</span>
                <%= if index == length(@breadcrumbs) - 1 do %>
                  <span class="ui-text-primary font-medium">{breadcrumb.path}</span>
                <% else %>
                  <.link
                    navigate={~p"/paths?parent=#{breadcrumb.id}"}
                    class="hover:ui-text-primary transition-colors"
                    data-test={"breadcrumb-#{breadcrumb.path}"}
                  >
                    {breadcrumb.path}
                  </.link>
                <% end %>
              <% end %>
            </div>
          </div>
        </div>
        
    <!-- Tab Navigation -->
        <div class="mt-8">
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
              data-test="tokens-tab"
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
              data-test="service-accounts-tab"
            >
              Service Accounts
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="domains"
              class={"px-4 py-2 -mb-px border-b-2 transition-colors " <>
                if @active_tab == "domains" do
                  "border-ui-inverted-foreground ui-text-primary font-medium"
                else
                  "border-transparent ui-text-secondary hover:ui-text-primary"
                end}
              data-test="domains-tab"
            >
              Domain Affinities
            </button>
            <button
              phx-click="switch_tab"
              phx-value-tab="hooks"
              class={"px-4 py-2 -mb-px border-b-2 transition-colors " <>
                if @active_tab == "hooks" do
                  "border-ui-inverted-foreground ui-text-primary font-medium"
                else
                  "border-transparent ui-text-secondary hover:ui-text-primary"
                end}
              data-test="hooks-tab"
            >
              Hooks
            </button>
          </div>
        </div>
        
    <!-- Telephone Tokens Tab -->
        <div :if={@active_tab == "tokens"} class="mt-8">
          <!-- Create Token Form -->
          <.form for={@token_form} phx-submit="create_token" class="flex gap-2 items-center">
            <div class="flex-1">
              <input
                type="text"
                name="token[name]"
                id="token_name"
                value=""
                placeholder="Token name (optional)"
                autocomplete="off"
                data-test="token-name-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <div class="flex-1">
              <input
                type="text"
                name="token[description]"
                id="token_description"
                value=""
                placeholder="Description (optional)"
                autocomplete="off"
                data-test="token-description-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <.button
              type="submit"
              phx-disable-with="Creating..."
              data-test="create-token-button"
              class="!w-auto px-6"
            >
              ● Create Token
            </.button>
          </.form>
          
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
                  Store this token securely. It cannot be retrieved again.
                </p>
                <div class="bg-[var(--ui-background)] p-4 rounded-lg">
                  <pre class="text-xs font-mono ui-text-primary overflow-x-auto whitespace-pre-wrap break-all">{@created_token}</pre>
                </div>
                <button
                  type="button"
                  phx-click={JS.dispatch("phx:copy", to: "#token-value")}
                  class="interactive-button-base text-button text-button-text"
                >
                  <.icon name="hero-clipboard" class="size-4 inline mr-2" /> Copy to Clipboard
                </button>
                <input id="token-value" type="hidden" value={@created_token} phx-hook="Copy" />
              </div>
            </:form>
          </.pop_up_form>
          
    <!-- Tokens List -->
          <div class="mt-8">
            <%= if @tokens == [] do %>
              <div class="text-center py-8 ui-text-secondary">
                No tokens found. Create one to get started.
              </div>
            <% else %>
              <table class="w-full border-separate border-spacing-y-1">
                <tbody>
                  <tr :for={token <- @tokens} class="group transition-colors">
                    <td class="py-3 px-4 rounded-full group-hover:bg-[var(--ui-foreground)]">
                      <div class="flex items-center justify-between gap-3">
                        <!-- Icon -->
                        <div class="flex-shrink-0">
                          <.icon name="hero-key" class="size-5 ui-text-primary" />
                        </div>
                        <!-- Token info -->
                        <div class="flex-1 min-w-0">
                          <div class="ui-text-primary">
                            <span class="font-medium">
                              {token.name || "Unnamed token"}
                            </span>
                            <%= if token.description do %>
                              <span class="ml-2 text-sm ui-text-secondary">
                                {token.description}
                              </span>
                            <% end %>
                          </div>
                          <div class="flex gap-4 text-xs ui-text-secondary mt-1">
                            <span>Created: {format_datetime(token.inserted_at)}</span>
                            <span>Expires: {format_datetime(token.expires_at)}</span>
                            <%= if token.last_used_at do %>
                              <span>Last used: {format_datetime(token.last_used_at)}</span>
                            <% else %>
                              <span>Never used</span>
                            <% end %>
                          </div>
                        </div>
                        <!-- Actions -->
                        <div class="flex justify-end items-center gap-2 flex-shrink-0">
                          <div class="group/actions relative inline-flex items-center gap-2">
                            <!-- Settings icon (always visible) -->
                            <div class="interactive-button-base icon-button flex items-center justify-center flex-shrink-0">
                              <.icon name="hero-cog-6-tooth" class="icon-button-icon" />
                            </div>
                            
    <!-- Expandable actions (visible on hover) -->
                            <div class="flex items-center gap-2 overflow-hidden max-w-0 opacity-0 group-hover/actions:max-w-[14rem] group-hover/actions:opacity-100 transition-all duration-300 ease-in-out">
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="revoke_token"
                                phx-value-id={token.id}
                                data-test="revoke-token-button"
                                data-confirm="Are you sure you want to revoke this token? This action cannot be undone."
                                title="Revoke"
                              >
                                <.icon name="hero-trash" class="icon-button-icon" />
                              </button>
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="open_edit_token"
                                phx-value-id={token.id}
                                data-test="edit-token-button"
                                title="Edit"
                              >
                                <.icon name="hero-pencil" class="icon-button-icon" />
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
        
    <!-- Edit Token Modal -->
        <.pop_up_form
          :if={@editing_token}
          id="edit-token-modal"
          title="Edit Token"
          title_align="left"
          on_cancel={JS.push("close_edit_token")}
        >
          <:form>
            <.form for={@edit_token_form} phx-submit="save_edit_token">
              <div class="space-y-4">
                <.input
                  field={@edit_token_form[:name]}
                  type="text"
                  label="Token Name"
                  placeholder="Enter token name (optional)"
                  phx-mounted={JS.focus()}
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
                <.input
                  field={@edit_token_form[:description]}
                  type="text"
                  label="Description"
                  placeholder="Enter description (optional)"
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
              </div>
              <.button type="submit" phx-disable-with="Saving...">
                ● Save Changes
              </.button>
            </.form>
          </:form>
        </.pop_up_form>
        
    <!-- Service Accounts Tab -->
        <div :if={@active_tab == "service_accounts"} class="mt-8">
          <!-- Create Service Account Form -->
          <.form
            for={@sa_form}
            phx-submit="create_service_account"
            class="flex gap-2 items-center"
          >
            <div class="flex-1">
              <input
                type="text"
                name="service_account[name]"
                id="service_account_name"
                value=""
                placeholder="Service account name"
                autocomplete="off"
                required
                data-test="service-account-name-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <div class="flex-1">
              <input
                type="text"
                name="service_account[description]"
                placeholder="Description (optional)"
                data-test="service-account-description-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <.button
              type="submit"
              phx-disable-with="Creating..."
              data-test="create-service-account-button"
              class="!w-auto px-6"
            >
              ● Create Account
            </.button>
          </.form>
          
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
                  class="interactive-button-base text-button text-button-text"
                >
                  <.icon name="hero-clipboard" class="size-4 inline mr-2" /> Copy to Clipboard
                </button>
                <input id="api-key-value" type="hidden" value={@created_api_key} phx-hook="Copy" />
              </div>
            </:form>
          </.pop_up_form>
          
    <!-- Service Accounts List -->
          <div class="mt-8">
            <%= if @service_accounts == [] do %>
              <div class="text-center py-8 ui-text-secondary">
                No service accounts found. Create one to enable auto-scaling.
              </div>
            <% else %>
              <table class="w-full border-separate border-spacing-y-1">
                <tbody>
                  <tr :for={sa <- @service_accounts} class="group transition-colors">
                    <td class="py-3 px-4 rounded-full group-hover:bg-[var(--ui-foreground)]">
                      <div class="flex items-center justify-between gap-3">
                        <!-- Icon -->
                        <div class="flex-shrink-0">
                          <.icon name="hero-user-circle" class="size-5 ui-text-primary" />
                        </div>
                        <!-- Service account info -->
                        <div class="flex-1 min-w-0">
                          <div class="ui-text-primary">
                            <span class="font-medium">{sa.name}</span>
                            <%= if sa.description do %>
                              <span class="ml-2 text-sm ui-text-secondary">
                                {sa.description}
                              </span>
                            <% end %>
                          </div>
                          <div class="flex gap-4 text-xs ui-text-secondary mt-1">
                            <span>Created: {format_datetime(sa.inserted_at)}</span>
                            <%= if sa.last_used_at do %>
                              <span>Last used: {format_datetime(sa.last_used_at)}</span>
                            <% else %>
                              <span>Never used</span>
                            <% end %>
                          </div>
                        </div>
                        <!-- Actions -->
                        <div class="flex justify-end items-center gap-2 flex-shrink-0">
                          <div class="group/actions relative inline-flex items-center gap-2">
                            <!-- Settings icon (always visible) -->
                            <div class="interactive-button-base icon-button flex items-center justify-center flex-shrink-0">
                              <.icon name="hero-cog-6-tooth" class="icon-button-icon" />
                            </div>
                            
    <!-- Expandable actions (visible on hover) -->
                            <div class="flex items-center gap-2 overflow-hidden max-w-0 opacity-0 group-hover/actions:max-w-[14rem] group-hover/actions:opacity-100 transition-all duration-300 ease-in-out">
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="revoke_service_account"
                                phx-value-id={sa.id}
                                data-test="revoke-service-account-button"
                                data-confirm="Are you sure you want to revoke this service account? This action cannot be undone."
                                title="Revoke"
                              >
                                <.icon name="hero-trash" class="icon-button-icon" />
                              </button>
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="open_edit_service_account"
                                phx-value-id={sa.id}
                                data-test="edit-service-account-button"
                                title="Edit"
                              >
                                <.icon name="hero-pencil" class="icon-button-icon" />
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
        
    <!-- Edit Service Account Modal -->
        <.pop_up_form
          :if={@editing_service_account}
          id="edit-service-account-modal"
          title="Edit Service Account"
          title_align="left"
          on_cancel={JS.push("close_edit_service_account")}
        >
          <:form>
            <.form for={@edit_service_account_form} phx-submit="save_edit_service_account">
              <div class="space-y-4">
                <.input
                  field={@edit_service_account_form[:name]}
                  type="text"
                  label="Service Account Name"
                  placeholder="Enter service account name"
                  phx-mounted={JS.focus()}
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
                <.input
                  field={@edit_service_account_form[:description]}
                  type="text"
                  label="Description"
                  placeholder="Enter description (optional)"
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
              </div>
              <.button type="submit" phx-disable-with="Saving...">
                ● Save Changes
              </.button>
            </.form>
          </:form>
        </.pop_up_form>
        
    <!-- Domain Affinities Tab -->
        <div :if={@active_tab == "domains"} class="mt-8">
          <!-- Create Domain Form -->
          <.form for={@domain_form} phx-submit="create_domain" class="flex gap-2 items-center">
            <div class="flex-1">
              <input
                type="text"
                name="domain[domain]"
                id="domain_domain"
                value=""
                placeholder="example.com or *.example.com"
                autocomplete="off"
                required
                data-test="domain-input"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>
            <.button
              type="submit"
              phx-disable-with="Adding..."
              data-test="create-domain-button"
              class="!w-auto px-6"
            >
              ● Add Domain
            </.button>
          </.form>
          
    <!-- Domain Affinities List -->
          <div class="mt-8">
            <%= if @domain_affinities == [] do %>
              <div class="text-center py-8 ui-text-secondary">
                No domain affinities configured. Add one to enable domain-based routing.
              </div>
            <% else %>
              <table class="w-full border-separate border-spacing-y-1">
                <tbody>
                  <tr :for={da <- @domain_affinities} class="group transition-colors">
                    <td class="py-3 px-4 rounded-full group-hover:bg-[var(--ui-foreground)]">
                      <div class="flex items-center justify-between gap-3">
                        <!-- Icon -->
                        <div class="flex-shrink-0">
                          <.icon name="hero-globe-alt" class="size-5 ui-text-primary" />
                        </div>
                        <!-- Domain info -->
                        <div class="flex-1 min-w-0">
                          <div class="ui-text-primary">
                            <span class="font-medium">{da.domain}</span>
                            <%= if String.starts_with?(da.domain, "*.") do %>
                              <span class="ml-2 text-xs px-2 py-1 rounded-full bg-[var(--ui-background)] ui-text-secondary">
                                wildcard
                              </span>
                            <% end %>
                          </div>
                          <div class="text-xs ui-text-secondary mt-1">
                            <span>Created: {format_datetime(da.inserted_at)}</span>
                          </div>
                        </div>
                        <!-- Actions -->
                        <div class="flex justify-end items-center gap-2 flex-shrink-0">
                          <div class="group/actions relative inline-flex items-center gap-2">
                            <!-- Settings icon (always visible) -->
                            <div class="interactive-button-base icon-button flex items-center justify-center flex-shrink-0">
                              <.icon name="hero-cog-6-tooth" class="icon-button-icon" />
                            </div>
                            
    <!-- Expandable actions (visible on hover) -->
                            <div class="flex items-center gap-2 overflow-hidden max-w-0 opacity-0 group-hover/actions:max-w-[14rem] group-hover/actions:opacity-100 transition-all duration-300 ease-in-out">
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="delete_domain"
                                phx-value-id={da.id}
                                data-test="delete-domain-button"
                                data-confirm="Are you sure you want to delete this domain affinity? This action cannot be undone."
                                title="Delete"
                              >
                                <.icon name="hero-trash" class="icon-button-icon" />
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
        
    <!-- Hooks Tab -->
        <div :if={@active_tab == "hooks"} class="mt-8">
          <!-- Create Hook Form -->
          <.form for={@hook_form} phx-submit="create_hook" class="space-y-4">
            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@hook_form[:name]}
                type="text"
                label="Hook Name"
                placeholder="Auth Hook"
                required
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
              <.input
                field={@hook_form[:execution_order]}
                type="number"
                label="Execution Order"
                value="0"
                min="0"
                required
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>

            <.input
              field={@hook_form[:description]}
              type="text"
              label="Description"
              placeholder="Verifies JWT tokens"
              class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
            />

            <div>
              <label class="block text-sm font-medium ui-text-primary mb-2">Target Type</label>
              <div class="flex gap-4">
                <label class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="hook[target_type]"
                    value="mount_point"
                    checked
                    class="ui-text-primary"
                  />
                  <span class="ui-text-primary">Mount Point (Internal)</span>
                </label>
                <label class="flex items-center gap-2">
                  <input
                    type="radio"
                    name="hook[target_type]"
                    value="http_url"
                    class="ui-text-primary"
                  />
                  <span class="ui-text-primary">HTTP URL (External)</span>
                </label>
              </div>
            </div>

            <div id="mount-point-target">
              <label class="block text-sm font-medium ui-text-primary mb-2">
                Target Mount Point
              </label>
              <select
                name="hook[target_path_id]"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              >
                <option value="">Select a mount point...</option>
                <%= for mp <- @mount_points do %>
                  <option value={mp.id}>{mp.full_path}</option>
                <% end %>
              </select>
            </div>

            <div id="http-url-target" style="display: none;">
              <.input
                field={@hook_form[:target_url]}
                type="text"
                label="Target URL"
                placeholder="https://auth.example.com/verify"
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
            </div>

            <div class="grid grid-cols-2 gap-4">
              <.input
                field={@hook_form[:timeout_ms]}
                type="number"
                label="Timeout (ms)"
                value="5000"
                min="1"
                max="60000"
                required
                class="w-full input ui-foreground ui-text-primary focus:outline-none focus:border-ui-inverted-foreground rounded-full"
              />
              <div>
                <label class="block text-sm font-medium ui-text-primary mb-2">
                  Forward Query Params
                </label>
                <input
                  type="checkbox"
                  name="hook[forward_query_params]"
                  value="true"
                  class="ui-text-primary"
                />
              </div>
            </div>

            <.button
              type="submit"
              phx-disable-with="Creating..."
              data-test="create-hook-button"
              class="!w-auto px-6"
            >
              ● Create Hook
            </.button>
          </.form>
          
    <!-- Hooks List -->
          <div class="mt-8">
            <%= if @hooks == [] do %>
              <div class="text-center py-8 ui-text-secondary">
                No hooks configured. Hooks allow you to preprocess requests before they reach the backend.
              </div>
            <% else %>
              <div class="mb-4 p-4 bg-[var(--ui-foreground)] rounded-lg ui-text-secondary text-sm">
                <strong>Request Flow:</strong>
                Client →
                <%= for {hook, idx} <- Enum.with_index(@hooks) do %>
                  Hook #{hook.execution_order} ({hook.name}) →
                <% end %>
                Backend
              </div>

              <table class="w-full border-separate border-spacing-y-1">
                <tbody>
                  <tr :for={hook <- @hooks} class="group transition-colors">
                    <td class="py-3 px-4 rounded-full group-hover:bg-[var(--ui-foreground)]">
                      <div class="flex items-center justify-between gap-3">
                        <!-- Order badge -->
                        <div class="flex-shrink-0">
                          <div class="w-8 h-8 rounded-full bg-[var(--ui-inverted-foreground)] ui-text-inverted flex items-center justify-center font-bold">
                            {hook.execution_order}
                          </div>
                        </div>
                        <!-- Hook info -->
                        <div class="flex-1 min-w-0">
                          <div class="ui-text-primary">
                            <span class="font-medium">{hook.name}</span>
                            <%= if hook.description do %>
                              <span class="ml-2 text-sm ui-text-secondary">
                                {hook.description}
                              </span>
                            <% end %>
                          </div>
                          <div class="flex gap-4 text-xs ui-text-secondary mt-1">
                            <span>
                              Target:
                              <%= if hook.target_type == "mount_point" do %>
                                <span class="font-mono">
                                  {if hook.target_path,
                                    do: hook.target_path.full_path,
                                    else: "Unknown"}
                                </span>
                              <% else %>
                                <span class="font-mono">{hook.target_url}</span>
                              <% end %>
                            </span>
                            <span>Timeout: {hook.timeout_ms}ms</span>
                            <span>
                              Status codes: [{Enum.join(hook.allowed_status_codes, ", ")}]
                            </span>
                          </div>
                        </div>
                        <!-- Actions -->
                        <div class="flex justify-end items-center gap-2 flex-shrink-0">
                          <div class="group/actions relative inline-flex items-center gap-2">
                            <!-- Settings icon (always visible) -->
                            <div class="interactive-button-base icon-button flex items-center justify-center flex-shrink-0">
                              <.icon name="hero-cog-6-tooth" class="icon-button-icon" />
                            </div>
                            
    <!-- Expandable actions (visible on hover) -->
                            <div class="flex items-center gap-2 overflow-hidden max-w-0 opacity-0 group-hover/actions:max-w-[14rem] group-hover/actions:opacity-100 transition-all duration-300 ease-in-out">
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="delete_hook"
                                phx-value-id={hook.id}
                                data-test="delete-hook-button"
                                data-confirm="Are you sure you want to delete this hook? This action cannot be undone."
                                title="Delete"
                              >
                                <.icon name="hero-trash" class="icon-button-icon" />
                              </button>
                              <button
                                type="button"
                                class="interactive-button-base icon-button flex-shrink-0"
                                phx-click="open_edit_hook"
                                phx-value-id={hook.id}
                                data-test="edit-hook-button"
                                title="Edit"
                              >
                                <.icon name="hero-pencil" class="icon-button-icon" />
                              </button>
                            </div>
                          </div>
                        </div>
                      </div>
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>
        
    <!-- Edit Hook Modal -->
        <.pop_up_form
          :if={@editing_hook}
          id="edit-hook-modal"
          title="Edit Hook"
          title_align="left"
          on_cancel={JS.push("close_edit_hook")}
        >
          <:form>
            <.form for={@edit_hook_form} phx-submit="save_edit_hook">
              <div class="space-y-4">
                <.input
                  field={@edit_hook_form[:name]}
                  type="text"
                  label="Hook Name"
                  required
                  phx-mounted={JS.focus()}
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
                <.input
                  field={@edit_hook_form[:description]}
                  type="text"
                  label="Description"
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
                <.input
                  field={@edit_hook_form[:timeout_ms]}
                  type="number"
                  label="Timeout (ms)"
                  min="1"
                  max="60000"
                  required
                  class="w-full input ui-foreground focus:outline-none focus:border-ui-text-primary rounded-full ui-text-primary"
                />
              </div>
              <.button type="submit" phx-disable-with="Saving...">
                ● Save Changes
              </.button>
            </.form>
          </:form>
        </.pop_up_form>
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
            # Load tokens, service accounts, domain affinities, and hooks
            tokens = TelephoneTokens.list_tokens_for_path(path_id)
            service_accounts = ServiceAccounts.list_service_accounts_for_path(path_id)
            domain_affinities = DomainAffinities.list_domain_affinities_for_path(path_id)
            hooks = Hooks.list_hooks_for_path(path_id)
            mount_points = Paths.list_mount_points(user.id)

            # Build breadcrumbs
            breadcrumbs = build_breadcrumbs(path)

            {:ok,
             assign(socket,
               path: path,
               user_role: role,
               active_tab: "tokens",
               tokens: tokens,
               service_accounts: service_accounts,
               domain_affinities: domain_affinities,
               hooks: hooks,
               mount_points: mount_points,
               breadcrumbs: breadcrumbs,
               token_form: to_form(%{}, as: "token"),
               sa_form: to_form(%{}, as: "service_account"),
               domain_form: to_form(%{}, as: "domain"),
               hook_form: to_form(%{}, as: "hook"),
               created_token: nil,
               created_api_key: nil,
               editing_token: nil,
               edit_token_form: nil,
               editing_service_account: nil,
               edit_service_account_form: nil,
               editing_hook: nil,
               edit_hook_form: nil
             )}
        end
    end
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, active_tab: tab)}
  end

  @impl true
  def handle_event("create_token", %{"token" => token_params}, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.path

    name = Map.get(token_params, "name", "")
    description = Map.get(token_params, "description", "")

    # Check if user has permission (owner or maintainer)
    if socket.assigns.user_role in ["owner", "maintainer"] do
      token_name = if name == "", do: nil, else: name
      desc = if description == "", do: nil, else: description

      case TelephoneTokens.generate_token(path, user, token_name, desc) do
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
  def handle_event("open_edit_token", %{"id" => token_id}, socket) do
    case TelephoneTokens.get_token(token_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Token not found")}

      token ->
        edit_form =
          to_form(
            %{"name" => token.name || "", "description" => token.description || ""},
            as: "edit_token"
          )

        {:noreply, assign(socket, editing_token: token, edit_token_form: edit_form)}
    end
  end

  @impl true
  def handle_event("close_edit_token", _params, socket) do
    {:noreply, assign(socket, editing_token: nil, edit_token_form: nil)}
  end

  @impl true
  def handle_event("save_edit_token", %{"edit_token" => token_params}, socket) do
    token = socket.assigns.editing_token

    if socket.assigns.user_role in ["owner", "maintainer"] do
      attrs = %{
        name: if(token_params["name"] == "", do: nil, else: token_params["name"]),
        description:
          if(token_params["description"] == "", do: nil, else: token_params["description"])
      }

      case TelephoneTokens.update_token(token.id, attrs) do
        {:ok, _updated_token} ->
          # Reload tokens
          tokens = TelephoneTokens.list_tokens_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(tokens: tokens, editing_token: nil, edit_token_form: nil)
           |> put_flash(:info, "Token updated successfully")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(edit_token_form: to_form(changeset, as: "edit_token"))
           |> put_flash(:error, "Failed to update token")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Token not found")}
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
          service_accounts =
            ServiceAccounts.list_service_accounts_for_path(socket.assigns.path.id)

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

  @impl true
  def handle_event("open_edit_service_account", %{"id" => sa_id}, socket) do
    case ServiceAccounts.get_service_account(sa_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Service account not found")}

      service_account ->
        edit_form =
          to_form(
            %{
              "name" => service_account.name,
              "description" => service_account.description || ""
            },
            as: "edit_service_account"
          )

        {:noreply,
         assign(socket,
           editing_service_account: service_account,
           edit_service_account_form: edit_form
         )}
    end
  end

  @impl true
  def handle_event("close_edit_service_account", _params, socket) do
    {:noreply, assign(socket, editing_service_account: nil, edit_service_account_form: nil)}
  end

  @impl true
  def handle_event("save_edit_service_account", %{"edit_service_account" => sa_params}, socket) do
    service_account = socket.assigns.editing_service_account

    if socket.assigns.user_role in ["owner", "maintainer"] do
      attrs = %{
        name: sa_params["name"],
        description: if(sa_params["description"] == "", do: nil, else: sa_params["description"])
      }

      case ServiceAccounts.update_service_account(service_account.id, attrs) do
        {:ok, _updated_sa} ->
          # Reload service accounts
          service_accounts =
            ServiceAccounts.list_service_accounts_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(
             service_accounts: service_accounts,
             editing_service_account: nil,
             edit_service_account_form: nil
           )
           |> put_flash(:info, "Service account updated successfully")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           socket
           |> assign(edit_service_account_form: to_form(changeset, as: "edit_service_account"))
           |> put_flash(:error, "Failed to update service account")}

        {:error, :not_found} ->
          {:noreply, put_flash(socket, :error, "Service account not found")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("create_domain", %{"domain" => domain_params}, socket) do
    if socket.assigns.user_role in ["owner", "maintainer"] do
      # Verify path is a mount point
      if socket.assigns.path.mount_point do
        attrs = %{
          domain: domain_params["domain"],
          path_id: socket.assigns.path.id
        }

        case DomainAffinities.create_domain_affinity(attrs) do
          {:ok, _domain_affinity} ->
            # Reload domain affinities
            domain_affinities =
              DomainAffinities.list_domain_affinities_for_path(socket.assigns.path.id)

            {:noreply,
             socket
             |> assign(domain_affinities: domain_affinities)
             |> put_flash(:info, "Domain affinity created successfully")}

          {:error, changeset} ->
            errors =
              Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
              |> Enum.map(fn {field, messages} ->
                "#{field}: #{Enum.join(messages, ", ")}"
              end)
              |> Enum.join("; ")

            {:noreply, put_flash(socket, :error, "Failed to create domain affinity: #{errors}")}
        end
      else
        {:noreply, put_flash(socket, :error, "Path must be a mount point")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("delete_domain", %{"id" => domain_id}, socket) do
    if socket.assigns.user_role in ["owner", "maintainer"] do
      case DomainAffinities.delete_domain_affinity(domain_id) do
        {:ok, _domain_affinity} ->
          # Reload domain affinities
          domain_affinities =
            DomainAffinities.list_domain_affinities_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(domain_affinities: domain_affinities)
           |> put_flash(:info, "Domain affinity deleted successfully")}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Failed to delete domain affinity")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("create_hook", %{"hook" => hook_params}, socket) do
    user = socket.assigns.current_scope.user
    path = socket.assigns.path

    if socket.assigns.user_role in ["owner", "maintainer"] do
      attrs = %{
        path_id: path.id,
        name: Map.get(hook_params, "name"),
        description: Map.get(hook_params, "description"),
        target_type: Map.get(hook_params, "target_type", "mount_point"),
        target_path_id: Map.get(hook_params, "target_path_id"),
        target_url: Map.get(hook_params, "target_url"),
        execution_order: String.to_integer(Map.get(hook_params, "execution_order", "0")),
        timeout_ms: String.to_integer(Map.get(hook_params, "timeout_ms", "5000")),
        forward_query_params: Map.get(hook_params, "forward_query_params") == "true"
      }

      case Hooks.create_hook(user.id, attrs) do
        {:ok, _hook} ->
          # Reload hooks
          hooks = Hooks.list_hooks_for_path(path.id)

          {:noreply,
           socket
           |> assign(hooks: hooks)
           |> put_flash(:info, "Hook created successfully")}

        {:error, reason} when is_binary(reason) ->
          {:noreply, put_flash(socket, :error, reason)}

        {:error, changeset} ->
          errors =
            Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)
            |> Enum.map(fn {field, messages} ->
              "#{field}: #{Enum.join(messages, ", ")}"
            end)
            |> Enum.join("; ")

          {:noreply, put_flash(socket, :error, "Failed to create hook: #{errors}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("delete_hook", %{"id" => hook_id}, socket) do
    user = socket.assigns.current_scope.user

    if socket.assigns.user_role in ["owner", "maintainer"] do
      case Hooks.get_hook(hook_id) do
        nil ->
          {:noreply, put_flash(socket, :error, "Hook not found")}

        hook ->
          case Hooks.delete_hook(user.id, hook) do
            {:ok, _deleted_hook} ->
              # Reload hooks
              hooks = Hooks.list_hooks_for_path(socket.assigns.path.id)

              {:noreply,
               socket
               |> assign(hooks: hooks)
               |> put_flash(:info, "Hook deleted successfully")}

            {:error, reason} when is_binary(reason) ->
              {:noreply, put_flash(socket, :error, reason)}

            {:error, _changeset} ->
              {:noreply, put_flash(socket, :error, "Failed to delete hook")}
          end
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  @impl true
  def handle_event("open_edit_hook", %{"id" => hook_id}, socket) do
    case Hooks.get_hook(hook_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Hook not found")}

      hook ->
        edit_form =
          to_form(
            %{
              "name" => hook.name,
              "description" => hook.description || "",
              "timeout_ms" => hook.timeout_ms
            },
            as: "edit_hook"
          )

        {:noreply, assign(socket, editing_hook: hook, edit_hook_form: edit_form)}
    end
  end

  @impl true
  def handle_event("close_edit_hook", _params, socket) do
    {:noreply, assign(socket, editing_hook: nil, edit_hook_form: nil)}
  end

  @impl true
  def handle_event("save_edit_hook", %{"edit_hook" => hook_params}, socket) do
    user = socket.assigns.current_scope.user
    hook = socket.assigns.editing_hook

    if socket.assigns.user_role in ["owner", "maintainer"] do
      attrs = %{
        name: hook_params["name"],
        description:
          if(hook_params["description"] == "", do: nil, else: hook_params["description"]),
        timeout_ms: String.to_integer(hook_params["timeout_ms"])
      }

      case Hooks.update_hook(user.id, hook, attrs) do
        {:ok, _updated_hook} ->
          # Reload hooks
          hooks = Hooks.list_hooks_for_path(socket.assigns.path.id)

          {:noreply,
           socket
           |> assign(hooks: hooks, editing_hook: nil, edit_hook_form: nil)
           |> put_flash(:info, "Hook updated successfully")}

        {:error, reason} when is_binary(reason) ->
          {:noreply, put_flash(socket, :error, reason)}

        {:error, changeset} ->
          {:noreply,
           socket
           |> assign(edit_hook_form: to_form(changeset, as: "edit_hook"))
           |> put_flash(:error, "Failed to update hook")}
      end
    else
      {:noreply, put_flash(socket, :error, "Requires owner or maintainer role")}
    end
  end

  defp format_datetime(nil), do: "N/A"

  defp format_datetime(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M UTC")
  end

  # Builds a breadcrumb trail from root to the current path
  defp build_breadcrumbs(nil), do: []

  defp build_breadcrumbs(path) do
    case path.parent_id do
      nil ->
        [path]

      parent_id ->
        case Paths.get_path(parent_id) do
          nil -> [path]
          parent -> build_breadcrumbs(parent) ++ [path]
        end
    end
  end
end
