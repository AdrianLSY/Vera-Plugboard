defmodule PlugboardWeb.Plugs.DomainAffinityRouter do
  @moduledoc """
  Checks if the incoming request domain has a domain affinity mapping.

  This plug determines whether a request should be handled by domain-based
  routing or pass through to normal application routes.

  ## Behavior

  - If domain has affinity: Allows request to continue to `ProxyController.proxy_domain`
  - If no affinity: Sets `:skip_domain_proxy` flag and passes through to normal routing

  This ensures:
  - `plugboard.example.com` → Admin UI and normal routes
  - `users.example.com` → Domain affinity routing (if configured)
  - Unknown domains → 404 from domain proxy (if no other routes match)

  ## Examples

      # In router.ex
      pipeline :domain_proxy do
        plug :accepts, ["json", "html"]
        plug PlugboardWeb.Plugs.DomainAffinityRouter
      end

      scope "/", PlugboardWeb do
        pipe_through :domain_proxy
        get "/*path", ProxyController, :proxy_domain
      end
  """

  import Plug.Conn
  alias Plugboard.MountStore

  def init(opts), do: opts

  def call(conn, _opts) do
    domain = conn.host

    case MountStore.match_by_domain(domain) do
      {:ok, {_path_id, _full_path}} ->
        # Domain has affinity - continue to proxy_domain action
        conn

      {:error, :not_found} ->
        # No domain affinity - set flag for proxy_domain action
        # Since domain affinity routes are last, this will result in 404
        conn
        |> put_private(:skip_domain_proxy, true)
    end
  end
end
