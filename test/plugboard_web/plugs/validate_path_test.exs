defmodule PlugboardWeb.Plugs.ValidatePathTest do
  use PlugboardWeb.ConnCase, async: false

  import Plugboard.AccountsFixtures
  alias Plugboard.Paths

  setup do
    # Create a valid mount point for testing
    user = user_fixture()

    {:ok, path} =
      Paths.create_path(%{
        path: "api",
        user_id: user.id
      })

    {:ok, _mount} = Paths.update_path(path, %{mount_point: true})
    Plugboard.MountStore.reload_all()

    :ok
  end

  describe "path validation" do
    test "allows valid paths", %{conn: conn} do
      conn = get(conn, "/proxies/api/users/123")
      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end

    test "allows paths with hyphens and underscores", %{conn: conn} do
      conn = get(conn, "/proxies/api/user-profile/test_123")
      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end

    test "rejects path traversal with ../", %{conn: conn} do
      conn = get(conn, "/proxies/api/../etc/passwd")

      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Path traversal not allowed"
             }
    end

    test "rejects path traversal with ..", %{conn: conn} do
      conn = get(conn, "/proxies/api/users/..")
      assert json_response(conn, 400)["error"] == "Invalid path"
    end

    test "rejects encoded path traversal", %{conn: conn} do
      # Note: Phoenix automatically decodes %2e%2e to .. before our plug sees it
      conn = get(conn, "/proxies/api/%2e%2e/etc")
      # So this will be caught as regular path traversal
      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Path traversal not allowed"
             }
    end

    test "rejects null bytes", %{conn: conn} do
      # Construct path with null byte
      path = "/proxies/api/test#{<<0>>}malicious"
      conn = get(conn, path)

      # Should be rejected
      assert conn.status == 400
    end

    test "rejects encoded null bytes", %{conn: conn} do
      # Note: Phoenix automatically decodes %00 to null byte before our plug sees it
      conn = get(conn, "/proxies/api/test%00malicious")
      # So this will be caught as regular null byte check
      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Null bytes not allowed in path"
             }
    end

    test "rejects excessively long segments", %{conn: conn} do
      # Create a segment longer than 255 characters
      long_segment = String.duplicate("a", 256)
      conn = get(conn, "/proxies/api/#{long_segment}")

      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Path segment exceeds maximum length of 255 bytes"
             }
    end

    test "rejects excessively deep paths", %{conn: conn} do
      # Create a path with 51 segments (exceeds max of 50)
      deep_path = Enum.map_join(1..51, "/", fn i -> "segment#{i}" end)
      conn = get(conn, "/proxies/#{deep_path}")

      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Path depth exceeds maximum of 50 segments"
             }
    end

    test "allows path at exactly max depth", %{conn: conn} do
      # Create a path with exactly 50 segments
      deep_path = Enum.map_join(1..50, "/", fn i -> "s#{i}" end)
      conn = get(conn, "/proxies/#{deep_path}")

      # Should pass validation (will 404 because no mount exists)
      assert json_response(conn, 404)
    end

    test "allows segment at exactly max length", %{conn: conn} do
      # Create a segment exactly 255 characters
      max_segment = String.duplicate("a", 255)
      conn = get(conn, "/proxies/api/#{max_segment}")

      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end
  end

  describe "POST requests validation" do
    test "validates POST request paths", %{conn: conn} do
      conn = post(conn, "/proxies/api/../malicious", %{data: "test"})

      assert json_response(conn, 400) == %{
               "error" => "Invalid path",
               "reason" => "Path traversal not allowed"
             }
    end

    test "allows valid POST requests", %{conn: conn} do
      conn = post(conn, "/proxies/api/users", %{name: "Test"})
      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end
  end

  describe "special characters" do
    test "allows unicode characters in paths", %{conn: conn} do
      conn = get(conn, "/proxies/api/users/josé")
      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end

    test "allows URL-encoded characters (except dangerous ones)", %{conn: conn} do
      conn = get(conn, "/proxies/api/files/my%20file")
      # Phase 3: Should pass validation but return 503 without telephone
      assert json_response(conn, 503)["error"] == "No telephone available for this path"
    end
  end
end
