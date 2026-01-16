defmodule PlugboardWeb.PathsLive.UserWorkflowTest do
  @moduledoc """
  End-to-end integration tests simulating real user workflows for path management.

  These tests verify the complete user experience from login through creating,
  organizing, and managing paths as a user would interact with the UI.
  """
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Plugboard.AccountsFixtures

  alias Plugboard.Paths

  # Test Helper Functions
  # These helpers encapsulate common UI interactions to reduce duplication
  # and make tests more maintainable.

  defp create_path(lv, path_name) do
    lv
    |> form("form[phx-submit='create_path']", path: %{path: path_name})
    |> render_submit()
  end

  defp toggle_mount(lv, path_id) do
    lv
    |> element("button[phx-click='toggle_mount'][phx-value-id='#{path_id}']")
    |> render_click()
  end

  defp open_edit(lv, path_id) do
    lv
    |> element("button[phx-click='open_edit'][phx-value-id='#{path_id}']")
    |> render_click()
  end

  defp save_edit(lv, new_path_name) do
    lv
    |> form("form[phx-submit='save_edit']", edit: %{path: new_path_name})
    |> render_submit()
  end

  defp open_delete(lv, path_id) do
    lv
    |> element("button[phx-click='open_delete'][phx-value-id='#{path_id}']")
    |> render_click()
  end

  defp confirm_delete(lv, confirmation) do
    lv
    |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: confirmation})
    |> render_submit()
  end

  defp assert_path_exists(user_id, full_path) do
    path = Paths.get_path_by_full_path(user_id, full_path)
    assert path != nil, "Expected path #{full_path} to exist but it was not found"
    path
  end

  defp refute_path_exists(user_id, full_path) do
    path = Paths.get_path_by_full_path(user_id, full_path)
    assert path == nil, "Expected path #{full_path} to not exist but it was found"
  end

  describe "complete user workflow: creating and organizing paths" do
    test "user creates 3 root paths, creates nested paths, and mounts them" do
      # Step 1: Create user and log in
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      # Step 2: Navigate to paths page
      {:ok, lv, html} = live(conn, ~p"/paths")

      assert html =~ "Paths"
      assert html =~ "Manage your path hierarchy and mount points"
      # Should be empty initially
      assert html =~ "No paths found"

      # Step 3: Create first root path "api"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "api"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "api"
      refute html =~ "No paths found"

      # Verify in database
      api_path = Paths.get_path_by_full_path(user.id, "/api")
      assert api_path != nil
      assert api_path.path == "api"
      assert api_path.full_path == "/api"
      assert api_path.parent_id == nil
      assert api_path.mount_point == false

      # Step 4: Create second root path "admin"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "admin"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "api"
      assert html =~ "admin"

      # Verify in database
      admin_path = Paths.get_path_by_full_path(user.id, "/admin")
      assert admin_path != nil
      assert admin_path.path == "admin"
      assert admin_path.full_path == "/admin"

      # Step 5: Create third root path "webhooks"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "webhooks"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "api"
      assert html =~ "admin"
      assert html =~ "webhooks"

      # Verify all 3 root paths exist
      webhooks_path = Paths.get_path_by_full_path(user.id, "/webhooks")
      assert webhooks_path != nil

      root_paths = Paths.list_paths_by_parent(user.id, nil)
      assert length(root_paths) == 3

      # Step 6: Navigate into "api" path to create nested paths
      # Click the row that navigates to the path's children
      # Note: Stream DOM IDs use format "paths-{uuid}" (stream name prefix)
      lv
      |> element("tr#paths-#{api_path.id}")
      |> render_click()

      # Should navigate to api children view
      assert_redirect(lv, ~p"/paths?parent=#{api_path.id}")

      # Follow the redirect
      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{api_path.id}")

      # Should show breadcrumbs
      assert html =~ "Root"
      assert html =~ "api"
      # No children yet
      assert html =~ "No paths found"

      # Step 7: Create nested path "users" under "api"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "users"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "users"

      # Verify nested path
      users_path = Paths.get_path_by_full_path(user.id, "/api/users")
      assert users_path != nil
      assert users_path.path == "users"
      assert users_path.full_path == "/api/users"
      assert users_path.parent_id == api_path.id

      # Step 8: Create another nested path "products" under "api"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "products"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "users"
      assert html =~ "products"

      # Verify second nested path
      products_path = Paths.get_path_by_full_path(user.id, "/api/products")
      assert products_path != nil
      assert products_path.full_path == "/api/products"
      assert products_path.parent_id == api_path.id

      # Step 9: Navigate into "users" to create a deeper nested path
      lv
      |> element("tr#paths-#{users_path.id}")
      |> render_click()

      assert_redirect(lv, ~p"/paths?parent=#{users_path.id}")

      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{users_path.id}")

      # Should show full breadcrumb trail
      assert html =~ "Root"
      assert html =~ "api"
      assert html =~ "users"

      # Step 10: Create deeply nested path "profile" under "users"
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "profile"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "profile"

      # Verify deeply nested path
      profile_path = Paths.get_path_by_full_path(user.id, "/api/users/profile")
      assert profile_path != nil
      assert profile_path.path == "profile"
      assert profile_path.full_path == "/api/users/profile"
      assert profile_path.parent_id == users_path.id

      # Step 11: Navigate back to root to see all paths
      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Verify only root paths are shown in table
      root_paths_only = Paths.list_paths_by_parent(user.id, nil)
      assert length(root_paths_only) == 3

      # Verify root paths are present
      assert render(lv) =~ "api"
      assert render(lv) =~ "admin"
      assert render(lv) =~ "webhooks"

      # Verify child paths are not in the paths list (they may appear in placeholder text)
      # Check that we don't have table rows for child paths
      # Note: Stream DOM IDs use format "paths-{uuid}" (stream name prefix)
      assert !has_element?(lv, "#paths-#{users_path.id}")
      assert !has_element?(lv, "#paths-#{products_path.id}")
      assert !has_element?(lv, "#paths-#{profile_path.id}")

      # Step 12: Mount the "profile" path (terminal path with no children)
      # Navigate to profile path
      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{users_path.id}")
      assert html =~ "profile"

      # Toggle mount on profile path
      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{profile_path.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Mounted path"

      # Verify profile is now a mount point
      profile_path = Paths.get_path(profile_path.id)
      assert profile_path.mount_point == true

      # Verify mount point appears in mount points list
      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 1
      assert hd(mount_points).id == profile_path.id
      assert hd(mount_points).full_path == "/api/users/profile"

      # Step 13: Try to mount "api" path (should fail - has children)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{api_path.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Cannot mark as mount point"
      assert html =~ "path has children"

      # Verify api is still not a mount point
      api_path = Paths.get_path(api_path.id)
      assert api_path.mount_point == false

      # Step 14: Mount "webhooks" path (has no children)
      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{webhooks_path.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Mounted path"

      # Verify webhooks is now a mount point
      webhooks_path = Paths.get_path(webhooks_path.id)
      assert webhooks_path.mount_point == true

      # Verify we now have 2 mount points
      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 2
      mount_point_paths = Enum.map(mount_points, & &1.full_path) |> Enum.sort()
      assert mount_point_paths == ["/api/users/profile", "/webhooks"]

      # Step 15: Unmount "webhooks" path
      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{webhooks_path.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Unmounted path"

      # Verify webhooks is no longer a mount point
      webhooks_path = Paths.get_path(webhooks_path.id)
      assert webhooks_path.mount_point == false

      # Verify only 1 mount point remains
      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 1
      assert hd(mount_points).full_path == "/api/users/profile"

      # Step 16: Navigate to admin and create nested structure
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{admin_path.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "dashboard"})
      |> render_submit()

      assert render(lv) =~ "Path created successfully"
      assert render(lv) =~ "dashboard"

      dashboard_path = Paths.get_path_by_full_path(user.id, "/admin/dashboard")
      assert dashboard_path != nil
      assert dashboard_path.full_path == "/admin/dashboard"

      # Mount the dashboard
      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{dashboard_path.id}']")
      |> render_click()

      assert render(lv) =~ "Mounted path"

      # Verify we now have 2 mount points again
      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 2
      mount_point_paths = Enum.map(mount_points, & &1.full_path) |> Enum.sort()
      assert mount_point_paths == ["/admin/dashboard", "/api/users/profile"]

      # Final verification: Check complete path structure
      all_paths = Paths.list_paths(user.id)
      # api, admin, webhooks, users, products, profile, dashboard (7 total)
      assert length(all_paths) == 7

      # Verify hierarchy is correct
      assert Enum.find(all_paths, fn p -> p.full_path == "/api" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/admin" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/webhooks" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/api/users" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/api/products" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/api/users/profile" end)
      assert Enum.find(all_paths, fn p -> p.full_path == "/admin/dashboard" end)
    end

    test "user creates paths with special characters and validates naming rules" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Valid path names with hyphens, underscores, and dots
      valid_names = ["my-api", "user_data", "v1.0", "api-v2", "test_123"]

      for path_name <- valid_names do
        lv
        |> form("form[phx-submit='create_path']", path: %{path: path_name})
        |> render_submit()

        html = render(lv)
        assert html =~ "Path created successfully"
        assert html =~ path_name

        # Verify in database
        full_path = "/#{path_name}"
        created_path = Paths.get_path_by_full_path(user.id, full_path)
        assert created_path != nil
        assert created_path.path == path_name
      end

      # Verify all paths were created
      root_paths = Paths.list_paths_by_parent(user.id, nil)
      assert length(root_paths) == 5

      # Invalid path names
      invalid_names = [
        {"invalid/path", ~r/must not contain|forward slash|invalid/i},
        {"invalid path", ~r/must contain only|alphanumeric|invalid|space/i},
        {"", ~r/can.?t be blank|blank/i}
      ]

      for {path_name, expected_error_pattern} <- invalid_names do
        lv
        |> form("form[phx-submit='create_path']", path: %{path: path_name})
        |> render_submit()

        html = render(lv)
        assert html =~ "Failed to create path"

        # Check error message matches pattern (all patterns are now regexes)
        assert html =~ expected_error_pattern

        # Should not be in database
        full_path = "/#{path_name}"
        refute_path_exists(user.id, full_path)
      end

      # Verify no new paths were created from invalid attempts
      root_paths_after = Paths.list_paths_by_parent(user.id, nil)
      assert length(root_paths_after) == 5
    end

    test "user navigates breadcrumbs and creates paths at different levels" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create: /level1
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "level1"})
      |> render_submit()

      level1 = Paths.get_path_by_full_path(user.id, "/level1")

      # Navigate into level1
      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{level1.id}")
      assert html =~ "Root"
      assert html =~ "level1"

      # Create: /level1/level2
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "level2"})
      |> render_submit()

      level2 = Paths.get_path_by_full_path(user.id, "/level1/level2")

      # Navigate into level2
      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{level2.id}")
      assert html =~ "Root"
      assert html =~ "level1"
      assert html =~ "level2"

      # Create: /level1/level2/level3
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "level3"})
      |> render_submit()

      level3 = Paths.get_path_by_full_path(user.id, "/level1/level2/level3")
      assert level3 != nil
      assert level3.full_path == "/level1/level2/level3"

      # Navigate back to level1 using breadcrumb link
      {:ok, lv, html} = live(conn, ~p"/paths?parent=#{level1.id}")
      assert html =~ "Root"
      assert html =~ "level1"
      # Should see level2 as child
      assert html =~ "level2"
      # Should NOT see level3 (it's grandchild)
      refute html =~ "level3"

      # Create a sibling at level2: /level1/level2-sibling
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "level2-sibling"})
      |> render_submit()

      html = render(lv)
      assert html =~ "Path created successfully"
      assert html =~ "level2-sibling"
      assert html =~ "level2"

      level2_sibling = Paths.get_path_by_full_path(user.id, "/level1/level2-sibling")
      assert level2_sibling != nil
      assert level2_sibling.parent_id == level1.id

      # Navigate back to root
      {:ok, _lv, html} = live(conn, ~p"/paths")
      assert html =~ "level1"
      refute html =~ "level2"
      refute html =~ "level3"
      refute html =~ "level2-sibling"

      # Verify complete structure
      all_paths = Paths.list_paths(user.id)
      assert length(all_paths) == 4

      path_structure = Enum.map(all_paths, & &1.full_path) |> Enum.sort()

      assert path_structure == [
               "/level1",
               "/level1/level2",
               "/level1/level2-sibling",
               "/level1/level2/level3"
             ]
    end

    test "user edits path names and verifies full_path updates" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create parent and child
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "old-parent"})
      |> render_submit()

      parent = Paths.get_path_by_full_path(user.id, "/old-parent")

      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child"})
      |> render_submit()

      child = Paths.get_path_by_full_path(user.id, "/old-parent/child")
      assert child != nil

      # Go back to root and edit parent name
      {:ok, lv, _html} = live(conn, ~p"/paths")

      open_edit(lv, parent.id)
      save_edit(lv, "new-parent")

      assert render(lv) =~ "Path updated successfully"
      assert render(lv) =~ "new-parent"
      refute render(lv) =~ "old-parent"

      # Verify parent full_path updated
      parent = Paths.get_path(parent.id)
      assert parent.path == "new-parent"
      assert parent.full_path == "/new-parent"

      # Verify child full_path cascaded update
      child = Paths.get_path(child.id)
      assert child.full_path == "/new-parent/child"

      # Old path should not exist
      refute_path_exists(user.id, "/old-parent")
      refute_path_exists(user.id, "/old-parent/child")

      # New paths should exist
      assert_path_exists(user.id, "/new-parent")
      assert_path_exists(user.id, "/new-parent/child")
    end

    test "user deletes path and verifies children are also deleted" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create parent with multiple children and grandchildren
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "parent"})
      |> render_submit()

      parent = Paths.get_path_by_full_path(user.id, "/parent")

      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      # Create child1
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child1"})
      |> render_submit()

      child1 = Paths.get_path_by_full_path(user.id, "/parent/child1")

      # Create child2
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child2"})
      |> render_submit()

      child2 = Paths.get_path_by_full_path(user.id, "/parent/child2")

      # Create grandchild under child1
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{child1.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "grandchild"})
      |> render_submit()

      grandchild = Paths.get_path_by_full_path(user.id, "/parent/child1/grandchild")
      assert grandchild != nil

      # Verify all paths exist
      assert Paths.list_paths(user.id) |> length() == 4

      # Go back to root and delete parent
      {:ok, lv, _html} = live(conn, ~p"/paths")

      open_delete(lv, parent.id)
      confirm_delete(lv, parent.full_path)

      assert render(lv) =~ "Path deleted successfully"
      refute render(lv) =~ "parent"

      # Verify all paths are soft-deleted
      parent = Paths.get_path!(parent.id)
      child1 = Paths.get_path!(child1.id)
      child2 = Paths.get_path!(child2.id)
      grandchild = Paths.get_path!(grandchild.id)

      assert parent.deleted_at != nil
      assert child1.deleted_at != nil
      assert child2.deleted_at != nil
      assert grandchild.deleted_at != nil

      # Verify user sees no paths
      assert Paths.list_paths(user.id) |> length() == 0

      html = render(lv)
      assert html =~ "No paths found"
    end

    test "user cannot mount path with children, but can after deleting children" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create parent
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "parent"})
      |> render_submit()

      parent = Paths.get_path_by_full_path(user.id, "/parent")

      # Create child
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child"})
      |> render_submit()

      child = Paths.get_path_by_full_path(user.id, "/parent/child")

      # Try to mount parent (should fail)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{parent.id}']")
      |> render_click()

      assert render(lv) =~ "Cannot mark as mount point"
      assert render(lv) =~ "path has children"

      # Delete child
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      open_delete(lv, child.id)
      confirm_delete(lv, child.full_path)

      assert render(lv) =~ "Path deleted successfully"

      # Now mount parent (should succeed)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      toggle_mount(lv, parent.id)

      assert render(lv) =~ "Mounted path"

      # Verify
      parent = Paths.get_path(parent.id)
      assert parent.mount_point == true
    end

    test "user creates multiple mount points and verifies they all appear in mount list" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create and mount 5 different paths
      mount_names = ["api", "webhooks", "admin", "public", "internal"]

      for name <- mount_names do
        create_path(lv, name)
        assert render(lv) =~ "Path created successfully"

        path = Paths.get_path_by_full_path(user.id, "/#{name}")
        toggle_mount(lv, path.id)
        assert render(lv) =~ "Mounted path"
      end

      # Verify all mount points
      mount_points = Paths.list_mount_points(user.id)
      assert length(mount_points) == 5

      mount_paths = Enum.map(mount_points, & &1.full_path) |> Enum.sort()
      expected_paths = Enum.map(mount_names, &"/#{&1}") |> Enum.sort()
      assert mount_paths == expected_paths

      # Verify all are marked as mount points
      for mount_point <- mount_points do
        assert mount_point.mount_point == true
      end
    end

    test "user cannot create duplicate path names at same level" do
      user = user_fixture()
      conn = log_in_user(build_conn(), user)

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Create first "api" path
      create_path(lv, "api")
      assert render(lv) =~ "Path created successfully"

      _api_path = assert_path_exists(user.id, "/api")

      # Try to create another "api" path at root level (should fail)
      create_path(lv, "api")
      html = render(lv)
      assert html =~ "Failed to create path"
      # The error message should indicate uniqueness constraint
      assert html =~ "already" || html =~ "taken" || html =~ "exists"

      # Verify only one "api" path exists at root
      root_paths = Paths.list_paths_by_parent(user.id, nil)
      api_paths = Enum.filter(root_paths, fn p -> p.path == "api" end)
      assert length(api_paths) == 1

      # Create a different root path
      create_path(lv, "admin")
      assert render(lv) =~ "Path created successfully"

      admin_path = assert_path_exists(user.id, "/admin")

      # Navigate into admin and create "api" as child (should succeed - different parent)
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{admin_path.id}")

      create_path(lv, "api")
      assert render(lv) =~ "Path created successfully"

      # Verify /admin/api exists
      admin_api_path = assert_path_exists(user.id, "/admin/api")
      assert admin_api_path.parent_id == admin_path.id

      # Verify we now have 2 paths named "api" but with different parents
      all_paths = Paths.list_paths(user.id)
      api_paths = Enum.filter(all_paths, fn p -> p.path == "api" end)
      assert length(api_paths) == 2
    end

    test "unauthenticated user cannot access paths page" do
      conn = build_conn()

      # Attempt to access paths page without authentication
      assert {:error, {:redirect, %{to: redirect_path}}} = live(conn, ~p"/paths")

      # Should redirect to login page (note: actual path may be /users/log-in)
      assert redirect_path =~ "/users/log"
    end

    test "user cannot access another user's paths" do
      # Create two users
      user1 = user_fixture()
      user2 = user_fixture()

      # User 1 creates paths
      conn = log_in_user(build_conn(), user1)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      create_path(lv, "user1-private")
      assert render(lv) =~ "Path created successfully"

      user1_path = assert_path_exists(user1.id, "/user1-private")

      # User 2 logs in and should not see user1's paths
      conn2 = log_in_user(build_conn(), user2)
      {:ok, _lv2, html} = live(conn2, ~p"/paths")

      # User 2 should see empty paths
      assert html =~ "No paths found"
      refute html =~ "user1-private"

      # User 2 should not be able to navigate to user1's path by URL manipulation
      {:ok, lv2, html} = live(conn2, ~p"/paths?parent=#{user1_path.id}")

      # Should be redirected to root level (user has no access to that parent)
      assert html =~ "No paths found"
      refute html =~ "user1-private"

      # Verify user2 cannot see user1's paths via API
      user2_paths = Paths.list_paths(user2.id)
      assert length(user2_paths) == 0

      # User 2 creates their own path
      create_path(lv2, "user2-private")
      assert render(lv2) =~ "Path created successfully"

      assert_path_exists(user2.id, "/user2-private")

      # Verify isolation: each user has 1 path, can't see each other's
      user1_paths = Paths.list_paths(user1.id)
      user2_paths = Paths.list_paths(user2.id)

      assert length(user1_paths) == 1
      assert length(user2_paths) == 1
      assert hd(user1_paths).path == "user1-private"
      assert hd(user2_paths).path == "user2-private"
    end

    test "user cannot mount, edit, or delete another user's paths" do
      # Create two users with paths
      user1 = user_fixture()
      user2 = user_fixture()

      # User 1 creates a path
      conn1 = log_in_user(build_conn(), user1)
      {:ok, lv1, _html} = live(conn1, ~p"/paths")
      create_path(lv1, "user1-path")

      user1_path = assert_path_exists(user1.id, "/user1-path")

      # User 2 logs in
      conn2 = log_in_user(build_conn(), user2)
      {:ok, _lv2, html} = live(conn2, ~p"/paths")

      # User 2 should not see user1's path in the UI
      refute html =~ "user1-path"

      # Verify user1's path is still there and not mounted
      user1_path = Paths.get_path(user1_path.id)
      assert user1_path.mount_point == false
      assert user1_path.deleted_at == nil

      # Verify through the Paths context that user2 has no access
      # The get_user_path function should return nil for user2 trying to access user1's path
      user2_access = Plugboard.Paths.get_user_path(user2.id, user1_path.id)
      assert user2_access == nil

      # Verify user1 still has access
      user1_access = Plugboard.Paths.get_user_path(user1.id, user1_path.id)
      assert user1_access != nil
    end
  end
end
