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

    {:ok, _mount} = Paths.update_path(user.id, path, %{mount_point: true})
    Plugboard.MountStore.reload_all()

    :ok
  end

  describe "path validation" do
    test "allows valid paths", %{conn: conn} do
      conn = get(conn, "/call/api/users/123")
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end

    test "allows paths with hyphens and underscores", %{conn: conn} do
      conn = get(conn, "/call/api/user-profile/test_123")
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end

    test "rejects path traversal with ../", %{conn: conn} do
      conn = get(conn, "/call/api/../etc/passwd")

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
      assert html_response(conn, 400) =~ "Invalid path"
    end

    test "rejects path traversal with ..", %{conn: conn} do
      conn = get(conn, "/call/api/users/..")
      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "rejects encoded path traversal", %{conn: conn} do
      # Note: Phoenix automatically decodes %2e%2e to .. before our plug sees it
      conn = get(conn, "/call/api/%2e%2e/etc")
      # So this will be caught as regular path traversal
      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "rejects null bytes", %{conn: conn} do
      # Construct path with null byte
      path = "/call/api/test#{<<0>>}malicious"
      conn = get(conn, path)

      # Should be rejected
      assert conn.status == 400
    end

    test "rejects encoded null bytes", %{conn: conn} do
      # Note: Phoenix automatically decodes %00 to null byte before our plug sees it
      conn = get(conn, "/call/api/test%00malicious")
      # So this will be caught as regular null byte check
      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "rejects excessively long segments", %{conn: conn} do
      # Create a segment longer than 255 characters
      long_segment = String.duplicate("a", 256)
      conn = get(conn, "/call/api/#{long_segment}")

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "rejects excessively deep paths", %{conn: conn} do
      # Create a path with 51 segments (exceeds max of 50)
      deep_path = Enum.map_join(1..51, "/", fn i -> "segment#{i}" end)
      conn = get(conn, "/call/#{deep_path}")

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "allows path at exactly max depth", %{conn: conn} do
      # Create a path with exactly 50 segments
      deep_path = Enum.map_join(1..50, "/", fn i -> "s#{i}" end)
      conn = get(conn, "/call/#{deep_path}")

      # Should pass validation (will 404 because no mount exists)
      assert conn.status == 404
    end

    test "allows segment at exactly max length", %{conn: conn} do
      # Create a segment exactly 255 characters
      max_segment = String.duplicate("a", 255)
      conn = get(conn, "/call/api/#{max_segment}")

      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end
  end

  describe "POST requests validation" do
    test "validates POST request paths", %{conn: conn} do
      conn = post(conn, "/call/api/../malicious", %{data: "test"})

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "allows valid POST requests", %{conn: conn} do
      conn = post(conn, "/call/api/users", %{name: "Test"})
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end
  end

  describe "special characters" do
    test "allows unicode characters in paths", %{conn: conn} do
      conn = get(conn, "/call/api/users/josé")
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end

    test "allows URL-encoded characters (except dangerous ones)", %{conn: conn} do
      conn = get(conn, "/call/api/files/my%20file")
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end
  end

  describe "edge cases" do
    test "rejects path with multiple validation failures (stops at first)", %{conn: conn} do
      # Create a path that violates multiple rules: has path traversal AND null byte
      # Should fail on path traversal check (which comes first)
      path = "/call/api/../etc#{<<0>>}malicious"
      conn = get(conn, path)

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "rejects null byte in middle of segment", %{conn: conn} do
      # Test null byte specifically in the middle (not at start/end)
      path = "/call/api/before#{<<0>>}after/segment"
      conn = get(conn, path)

      assert conn.status == 400
      assert html_response(conn, 400) =~ "400"
    end

    test "allows multibyte unicode characters (emoji)", %{conn: conn} do
      # Test that multibyte characters are properly handled
      conn = get(conn, "/call/api/files/document-📄")
      # Phase 5: Should pass validation but return 503 without telephone (HTML response)
      assert conn.status == 503
      assert html_response(conn, 503) =~ "503"
    end
  end
end
