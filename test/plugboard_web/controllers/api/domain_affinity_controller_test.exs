defmodule PlugboardWeb.Api.DomainAffinityControllerTest do
  use PlugboardWeb.ConnCase, async: true

  import Plugboard.AccountsFixtures

  alias Plugboard.DomainAffinities
  alias Plugboard.Paths

  describe "POST /api/paths/:path_id/domain-affinities" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      # Create a mount point (required for domain affinities)
      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      %{conn: conn, user: user, path: path}
    end

    test "creates domain affinity with valid params as owner", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{
               "id" => id,
               "domain" => "api.example.com",
               "path_id" => path_id,
               "inserted_at" => _
             } = json_response(conn, 201)

      assert is_binary(id)
      assert path_id == path.id
    end

    test "creates domain affinity as maintainer", %{conn: conn, user: user, path: path} do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn =
        conn
        |> recycle()
        |> log_in_user(maintainer)
        |> post(~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{"id" => _} = json_response(conn, 201)
    end

    test "rejects creation as viewer", %{conn: conn, user: user, path: path} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn =
        conn
        |> recycle()
        |> log_in_user(viewer)
        |> post(~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{"error" => "Requires owner or maintainer role"} = json_response(conn, 403)
    end

    test "rejects creation with no access", %{conn: conn, path: path} do
      other_user = user_fixture()

      conn =
        conn
        |> recycle()
        |> log_in_user(other_user)
        |> post(~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{"error" => "Requires owner or maintainer role"} = json_response(conn, 403)
    end

    test "rejects creation for non-mount path", %{conn: conn, user: user} do
      # Create a non-mount path
      {:ok, non_mount_path} =
        Paths.create_path(%{
          path: "regular",
          user_id: user.id,
          mount_point: false
        })

      conn =
        post(conn, ~p"/api/paths/#{non_mount_path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "regular.example.com"
          }
        })

      assert %{"error" => "Path must be a mount point"} = json_response(conn, 400)
    end

    test "rejects creation for non-existent path", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/paths/#{fake_id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{"error" => "Path not found"} = json_response(conn, 404)
    end

    test "rejects invalid domain format", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => ""
          }
        })

      assert %{"error" => "Validation failed", "details" => details} = json_response(conn, 422)
      assert details["domain"]
    end

    test "rejects duplicate domain", %{conn: conn, user: user, path: path} do
      # Create first domain affinity
      {:ok, _} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "api.example.com",
          path_id: path.id
        })

      conn =
        post(conn, ~p"/api/paths/#{path.id}/domain-affinities", %{
          "domain_affinity" => %{
            "domain" => "api.example.com"
          }
        })

      assert %{"error" => "Validation failed", "details" => details} = json_response(conn, 422)
      assert details["domain"]
    end
  end

  describe "GET /api/paths/:path_id/domain-affinities" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      %{conn: conn, user: user, path: path}
    end

    test "lists domain affinities for path as owner", %{conn: conn, user: user, path: path} do
      {:ok, _da1} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "api1.example.com",
          path_id: path.id
        })

      {:ok, _da2} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "api2.example.com",
          path_id: path.id
        })

      conn = get(conn, ~p"/api/paths/#{path.id}/domain-affinities")

      assert %{"domain_affinities" => affinities} = json_response(conn, 200)
      assert length(affinities) == 2

      domains = Enum.map(affinities, & &1["domain"])
      assert "api1.example.com" in domains
      assert "api2.example.com" in domains
    end

    test "lists domain affinities as viewer", %{conn: conn, user: user, path: path} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      {:ok, _} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "api.example.com",
          path_id: path.id
        })

      conn =
        conn
        |> recycle()
        |> log_in_user(viewer)
        |> get(~p"/api/paths/#{path.id}/domain-affinities")

      assert %{"domain_affinities" => [_]} = json_response(conn, 200)
    end

    test "rejects listing with no access", %{conn: conn, path: path} do
      other_user = user_fixture()

      conn =
        conn
        |> recycle()
        |> log_in_user(other_user)
        |> get(~p"/api/paths/#{path.id}/domain-affinities")

      assert %{"error" => "You do not have access to this path"} = json_response(conn, 403)
    end

    test "returns empty list when no domain affinities", %{conn: conn, path: path} do
      conn = get(conn, ~p"/api/paths/#{path.id}/domain-affinities")

      assert %{"domain_affinities" => []} = json_response(conn, 200)
    end
  end

  describe "DELETE /api/domain-affinities/:id" do
    setup %{conn: conn} do
      user = user_fixture()
      conn = log_in_user(conn, user)

      {:ok, path} =
        Paths.create_path(%{
          path: "api",
          user_id: user.id,
          mount_point: true
        })

      {:ok, domain_affinity} =
        DomainAffinities.create_domain_affinity(user.id, %{
          domain: "api.example.com",
          path_id: path.id
        })

      %{conn: conn, user: user, path: path, domain_affinity: domain_affinity}
    end

    test "deletes domain affinity as owner", %{conn: conn, domain_affinity: da} do
      conn = delete(conn, ~p"/api/domain-affinities/#{da.id}")

      assert %{"message" => "Domain affinity deleted successfully"} = json_response(conn, 200)
      assert DomainAffinities.get_domain_affinity(da.id) == nil
    end

    test "deletes domain affinity as maintainer", %{
      conn: conn,
      user: user,
      path: path,
      domain_affinity: da
    } do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn =
        conn
        |> recycle()
        |> log_in_user(maintainer)
        |> delete(~p"/api/domain-affinities/#{da.id}")

      assert %{"message" => "Domain affinity deleted successfully"} = json_response(conn, 200)
    end

    test "rejects deletion as viewer", %{conn: conn, user: user, path: path, domain_affinity: da} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn =
        conn
        |> recycle()
        |> log_in_user(viewer)
        |> delete(~p"/api/domain-affinities/#{da.id}")

      assert %{"error" => "Requires owner or maintainer role"} = json_response(conn, 403)
    end

    test "rejects deletion with no access", %{conn: conn, domain_affinity: da} do
      other_user = user_fixture()

      conn =
        conn
        |> recycle()
        |> log_in_user(other_user)
        |> delete(~p"/api/domain-affinities/#{da.id}")

      assert %{"error" => "Requires owner or maintainer role"} = json_response(conn, 403)
    end

    test "returns 404 for non-existent domain affinity", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn = delete(conn, ~p"/api/domain-affinities/#{fake_id}")

      assert %{"error" => "Domain affinity not found"} = json_response(conn, 404)
    end
  end
end
