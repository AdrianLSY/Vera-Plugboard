defmodule PlugboardWeb.Plugs.DomainAffinityRouterTest do
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.DomainAffinities
  alias PlugboardWeb.Plugs.DomainAffinityRouter

  describe "call/2" do
    setup do
      user = user_fixture()

      # Create a mount point
      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      # Reload MountStore to pick up the new mount point
      Plugboard.MountStore.reload_all()

      %{user: user, path: path}
    end

    test "passes through unchanged when domain has affinity", %{conn: conn, path: path} do
      # Create a domain affinity
      {:ok, _da} =
        DomainAffinities.create_domain_affinity(%{
          domain: "api.example.com",
          path_id: path.id
        })

      # Reload MountStore to pick up the domain affinity
      Plugboard.MountStore.reload_all()

      # Build a conn with the domain that has affinity
      conn =
        conn
        |> Map.put(:host, "api.example.com")
        |> DomainAffinityRouter.call([])

      # Should NOT set skip_domain_proxy
      refute conn.private[:skip_domain_proxy]
    end

    test "sets :skip_domain_proxy when domain has no affinity", %{conn: conn} do
      # Build a conn with a domain that has no affinity
      conn =
        conn
        |> Map.put(:host, "unknown.example.com")
        |> DomainAffinityRouter.call([])

      # Should set skip_domain_proxy to true
      assert conn.private[:skip_domain_proxy] == true
    end

    test "init/1 returns opts unchanged" do
      opts = [some: :option]
      assert DomainAffinityRouter.init(opts) == opts
    end
  end
end
