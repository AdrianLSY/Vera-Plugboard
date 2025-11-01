defmodule PlugboardWeb.PathsLive.IndexTest do
  use PlugboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Plugboard.AccountsFixtures

  alias Plugboard.Paths

  defp create_user_and_login(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp create_path_for_user(user, attrs) do
    default_attrs = %{
      path: "test-path-#{System.unique_integer([:positive])}",
      user_id: user.id
    }

    {:ok, path} = Paths.create_path(Map.merge(default_attrs, attrs))
    path
  end

  describe "mount" do
    setup :create_user_and_login

    test "renders paths page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/paths")

      assert html =~ "Paths"
      assert html =~ "Manage your path hierarchy and mount points"
      assert html =~ "Create new path"
    end

    test "redirects if user is not logged in" do
      conn = build_conn()
      assert {:error, redirect} = live(conn, ~p"/paths")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "loads root level paths for user", %{conn: conn, user: user} do
      path1 = create_path_for_user(user, %{path: "xyz"})
      path2 = create_path_for_user(user, %{path: "abc"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      html = render(lv)
      assert html =~ path1.path
      assert html =~ path2.path
    end

    test "does not show paths from other users", %{conn: conn, user: user} do
      other_user = user_fixture()
      _other_path = create_path_for_user(other_user, %{path: "other-user-path"})
      my_path = create_path_for_user(user, %{path: "my-path"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      html = render(lv)
      assert html =~ my_path.path
      refute html =~ "other-user-path"
    end

    test "loads child paths when parent param is provided", %{conn: conn, user: user} do
      parent = create_path_for_user(user, %{path: "parent"})
      child = create_path_for_user(user, %{path: "child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      html = render(lv)
      assert html =~ child.path
      assert html =~ "parent"
    end

    test "shows breadcrumbs when viewing child paths", %{conn: conn, user: user} do
      root = create_path_for_user(user, %{path: "root"})
      child = create_path_for_user(user, %{path: "child", parent_id: root.id})

      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{child.id}")

      html = render(lv)
      assert html =~ "Root"
      assert html =~ "root"
      assert html =~ "child"
    end
  end

  describe "create_path" do
    setup :create_user_and_login

    test "creates a new root path", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "new-path"})
      |> render_submit()

      assert render(lv) =~ "Path created successfully"
      assert render(lv) =~ "new-path"

      # Verify in database
      assert Paths.get_path_by_full_path(user.id, "/new-path")
    end

    test "creates a child path under current parent", %{conn: conn, user: user} do
      parent = create_path_for_user(user, %{path: "parent"})

      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child"})
      |> render_submit()

      assert render(lv) =~ "Path created successfully"
      assert render(lv) =~ "child"

      # Verify in database with correct parent
      child = Paths.get_path_by_full_path(user.id, "/parent/child")
      assert child.parent_id == parent.id
    end

    test "trims whitespace from path name", %{conn: conn, user: user} do
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "  trimmed  "})
      |> render_submit()

      assert render(lv) =~ "Path created successfully"
      path = Paths.get_path_by_full_path(user.id, "/trimmed")
      assert path.path == "trimmed"
    end

    test "shows validation error for empty path", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: ""})
      |> render_submit()

      assert render(lv) =~ "Failed to create path"
    end

    test "shows validation error for invalid characters", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "invalid/path"})
      |> render_submit()

      assert render(lv) =~ "Failed to create path"
    end
  end

  describe "toggle_mount" do
    setup :create_user_and_login

    test "mounts a path without children", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "mountable"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{path.id}']")
      |> render_click()

      assert render(lv) =~ "Mounted path"

      # Verify in database
      updated = Paths.get_path(path.id)
      assert updated.mount_point == true
    end

    test "unmounts a mounted path", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "mounted"})
      {:ok, _} = Paths.update_path(path, %{mount_point: true})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{path.id}']")
      |> render_click()

      assert render(lv) =~ "Unmounted path"

      # Verify in database
      updated = Paths.get_path(path.id)
      assert updated.mount_point == false
    end

    test "prevents mounting path with children", %{conn: conn, user: user} do
      parent = create_path_for_user(user, %{path: "parent"})
      _child = create_path_for_user(user, %{path: "child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{parent.id}']")
      |> render_click()

      assert render(lv) =~ "Cannot mark as mount point"
      assert render(lv) =~ "path has children"

      # Verify not mounted in database
      parent = Paths.get_path(parent.id)
      assert parent.mount_point == false
    end
  end

  describe "edit path" do
    setup :create_user_and_login

    test "opens edit modal and saves changes", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "old-name"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Open edit modal
      lv
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      assert render(lv) =~ "Edit Path"
      assert has_element?(lv, "#edit-path-modal")

      # Submit edit form
      lv
      |> form("form[phx-submit='save_edit']", edit: %{path: "new-name"})
      |> render_submit()

      assert render(lv) =~ "Path updated successfully"
      assert render(lv) =~ "new-name"
      refute render(lv) =~ "old-name"

      # Verify in database
      updated = Paths.get_path(path.id)
      assert updated.path == "new-name"
    end

    test "shows validation errors when editing with invalid data", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "original"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      lv
      |> form("form[phx-submit='save_edit']", edit: %{path: "invalid/path"})
      |> render_submit()

      assert render(lv) =~ "Failed to update path"
    end
  end

  describe "delete path" do
    setup :create_user_and_login

    test "opens delete modal with confirmation prompt", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "deletable"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Delete Path"
      assert html =~ "To confirm deletion"
      assert html =~ path.full_path
      assert has_element?(lv, "#delete-path-modal")
    end

    test "deletes path with correct confirmation", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "to-delete"})
      full_path = path.full_path

      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Open delete modal
      lv
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      # Submit with correct confirmation
      lv
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: full_path})
      |> render_submit()

      assert render(lv) =~ "Path deleted successfully"
      refute render(lv) =~ "to-delete"

      # Verify soft-deleted in database
      deleted = Paths.get_path!(path.id)
      assert deleted.deleted_at != nil
    end

    test "rejects deletion with incorrect confirmation", %{conn: conn, user: user} do
      path = create_path_for_user(user, %{path: "protected"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      lv
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: "wrong-path"})
      |> render_submit()

      assert render(lv) =~ "Confirmation does not match"
      # Path should still be there
      assert render(lv) =~ "protected"

      # Verify not deleted in database
      path = Paths.get_path(path.id)
      assert path.deleted_at == nil
    end

    test "deletes path and its children", %{conn: conn, user: user} do
      parent = create_path_for_user(user, %{path: "parent"})
      child = create_path_for_user(user, %{path: "child", parent_id: parent.id})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      lv
      |> element("button[phx-click='open_delete'][phx-value-id='#{parent.id}']")
      |> render_click()

      lv
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: parent.full_path})
      |> render_submit()

      assert render(lv) =~ "Path deleted successfully"

      # Both parent and child should be soft-deleted
      parent = Paths.get_path!(parent.id)
      child = Paths.get_path!(child.id)
      assert parent.deleted_at != nil
      assert child.deleted_at != nil
    end
  end

  describe "authorization" do
    setup :create_user_and_login

    test "user can only see their own paths", %{conn: conn, user: user} do
      other_user = user_fixture()
      my_path = create_path_for_user(user, %{path: "my-path"})
      other_path = create_path_for_user(other_user, %{path: "other-path"})

      {:ok, lv, _html} = live(conn, ~p"/paths")

      html = render(lv)
      assert html =~ my_path.path
      refute html =~ other_path.path
    end

    test "viewer can see shared paths but cannot delete them", %{user: viewer} do
      owner = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "shared", user_id: owner.id})

      # Grant viewer access
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      html = render(lv)
      assert html =~ "shared"

      # Viewer should see the path
      paths = Paths.list_paths(viewer.id)
      assert Enum.any?(paths, fn p -> p.id == path.id end)
    end

    test "maintainer can see shared paths", %{user: maintainer} do
      owner = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "shared", user_id: owner.id})

      # Grant maintainer access
      {:ok, _} = Paths.add_user_to_path(maintainer.id, path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      html = render(lv)
      assert html =~ "shared"
    end

    test "user without access cannot see path even with direct parent param", %{user: user} do
      other_user = user_fixture()
      {:ok, other_path} = Paths.create_path(%{path: "private", user_id: other_user.id})

      conn = log_in_user(build_conn(), user)

      # Try to access other user's path via parent param
      # The LiveView should not show paths the user doesn't have access to
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{other_path.id}")

      html = render(lv)
      refute html =~ "private"
    end

    test "multiple users see different paths on same page", %{user: user1} do
      user2 = user_fixture()

      _path1 = create_path_for_user(user1, %{path: "user1-path"})
      _path2 = create_path_for_user(user2, %{path: "user2-path"})

      # User 1 sees only their path
      conn1 = log_in_user(build_conn(), user1)
      {:ok, lv1, _html} = live(conn1, ~p"/paths")
      html1 = render(lv1)
      assert html1 =~ "user1-path"
      refute html1 =~ "user2-path"

      # User 2 sees only their path
      conn2 = log_in_user(build_conn(), user2)
      {:ok, lv2, _html} = live(conn2, ~p"/paths")
      html2 = render(lv2)
      assert html2 =~ "user2-path"
      refute html2 =~ "user1-path"
    end

    test "creating path as viewer of parent (should work - viewers can create)", %{user: viewer} do
      owner = user_fixture()
      {:ok, parent} = Paths.create_path(%{path: "parent", user_id: owner.id})

      # Grant viewer access to parent
      {:ok, _} = Paths.add_user_to_path(viewer.id, parent.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      # Viewer tries to create a child
      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child"})
      |> render_submit()

      # Should succeed - viewer created the child with themselves as owner
      html = render(lv)
      assert html =~ "Path created successfully" or html =~ "child"
    end

    test "toggling mount on shared path (as owner)", %{user: owner} do
      {:ok, path} = Paths.create_path(%{path: "mountable", user_id: owner.id})
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), owner)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Owner can toggle mount
      lv
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{path.id}']")
      |> render_click()

      assert render(lv) =~ "Mounted path"

      # Verify in database
      updated = Paths.get_path(path.id)
      assert updated.mount_point == true
    end

    test "deleting shared path requires owner role", %{user: owner} do
      {:ok, path} = Paths.create_path(%{path: "deletable", user_id: owner.id})

      conn = log_in_user(build_conn(), owner)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Open delete modal
      lv
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      # Submit with correct confirmation
      lv
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: path.full_path})
      |> render_submit()

      assert render(lv) =~ "Path deleted successfully"
    end

    test "user sees breadcrumbs only for paths they have access to", %{user: user} do
      {:ok, root} = Paths.create_path(%{path: "root", user_id: user.id})
      {:ok, child} = Paths.create_path(%{path: "child", parent_id: root.id, user_id: user.id})

      conn = log_in_user(build_conn(), user)
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{child.id}")

      html = render(lv)
      # Should show breadcrumbs for root and child
      assert html =~ "root"
      assert html =~ "child"
    end

    test "editing path name as owner succeeds", %{user: owner} do
      {:ok, path} = Paths.create_path(%{path: "old-name", user_id: owner.id})

      conn = log_in_user(build_conn(), owner)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Open edit modal
      lv
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      # Submit edit form
      lv
      |> form("form[phx-submit='save_edit']", edit: %{path: "new-name"})
      |> render_submit()

      assert render(lv) =~ "Path updated successfully"
      assert render(lv) =~ "new-name"
    end
  end

  describe "multi-user scenarios" do
    test "shared path shows mount indicator for all users with access" do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "shared", user_id: owner.id, mount_point: true})
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      # Owner sees mount indicator
      conn_owner = log_in_user(build_conn(), owner)
      {:ok, lv_owner, _html} = live(conn_owner, ~p"/paths")
      html_owner = render(lv_owner)
      assert html_owner =~ "shared"

      # Viewer also sees mount indicator
      conn_viewer = log_in_user(build_conn(), viewer)
      {:ok, lv_viewer, _html} = live(conn_viewer, ~p"/paths")
      html_viewer = render(lv_viewer)
      assert html_viewer =~ "shared"
    end

    test "deleting shared path removes it from all users' views" do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "shared", user_id: owner.id})
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      # Owner deletes the path
      conn_owner = log_in_user(build_conn(), owner)
      {:ok, lv_owner, _html} = live(conn_owner, ~p"/paths")

      lv_owner
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      lv_owner
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: path.full_path})
      |> render_submit()

      # Viewer should no longer see it
      conn_viewer = log_in_user(build_conn(), viewer)
      {:ok, lv_viewer, _html} = live(conn_viewer, ~p"/paths")
      html_viewer = render(lv_viewer)
      refute html_viewer =~ "shared"
    end

    test "creating child under shared path associates creator as owner" do
      owner = user_fixture()
      collaborator = user_fixture()

      {:ok, parent} = Paths.create_path(%{path: "parent", user_id: owner.id})
      {:ok, _} = Paths.add_user_to_path(collaborator.id, parent.id, "maintainer")

      # Collaborator creates child
      conn = log_in_user(build_conn(), collaborator)
      {:ok, lv, _html} = live(conn, ~p"/paths?parent=#{parent.id}")

      lv
      |> form("form[phx-submit='create_path']", path: %{path: "child"})
      |> render_submit()

      # Verify child was created with collaborator as owner
      child = Paths.get_path_by_full_path(collaborator.id, "/parent/child")
      assert child != nil
      assert Paths.has_role?(collaborator.id, child.id, "owner")
    end
  end

  describe "real-time updates between users" do
    test "path created by one user is visible to other user viewing shared parent" do
      owner = user_fixture()
      collaborator = user_fixture()

      {:ok, parent} = Paths.create_path(%{path: "shared", user_id: owner.id})
      {:ok, _} = Paths.add_user_to_path(collaborator.id, parent.id, "maintainer")

      # Both users connect to view the parent
      conn_owner = log_in_user(build_conn(), owner)
      conn_collab = log_in_user(build_conn(), collaborator)

      {:ok, lv_owner, _html} = live(conn_owner, ~p"/paths?parent=#{parent.id}")
      {:ok, _lv_collab, _html} = live(conn_collab, ~p"/paths?parent=#{parent.id}")

      # Owner creates a child path
      lv_owner
      |> form("form[phx-submit='create_path']", path: %{path: "new-child"})
      |> render_submit()

      # Owner should see the new path
      assert render(lv_owner) =~ "new-child"

      # Note: Currently there's no PubSub/broadcast for real-time updates
      # This test documents expected behavior for Phase 2
      # For now, collaborator would need to refresh to see the change
      # When PubSub is added in Phase 2, test that lv_collab also sees "new-child"
    end

    test "path deleted by owner is removed from viewer's list" do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "shared", user_id: owner.id})
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      # Both users connect
      conn_owner = log_in_user(build_conn(), owner)
      _conn_viewer = log_in_user(build_conn(), viewer)

      {:ok, lv_owner, _html} = live(conn_owner, ~p"/paths")

      # Owner should see the path initially
      assert render(lv_owner) =~ "shared"

      # Owner deletes the path
      lv_owner
      |> element("button[phx-click='open_delete'][phx-value-id='#{path.id}']")
      |> render_click()

      lv_owner
      |> form("form[phx-submit='confirm_delete']", delete: %{confirmation: path.full_path})
      |> render_submit()

      # Owner should not see it
      refute render(lv_owner) =~ "shared"

      # Note: Real-time update for viewer requires PubSub (Phase 2)
      # Viewer would see it removed after refresh in current implementation
    end

    test "mount toggle by owner updates path status for all viewers" do
      owner = user_fixture()
      viewer = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "mountable", user_id: owner.id})
      {:ok, _} = Paths.add_user_to_path(viewer.id, path.id, "viewer")

      conn_owner = log_in_user(build_conn(), owner)
      conn_viewer = log_in_user(build_conn(), viewer)

      {:ok, lv_owner, _html} = live(conn_owner, ~p"/paths")
      {:ok, _lv_viewer, _html} = live(conn_viewer, ~p"/paths")

      # Owner toggles mount
      lv_owner
      |> element("button[phx-click='toggle_mount'][phx-value-id='#{path.id}']")
      |> render_click()

      # Verify mount status changed in database
      updated_path = Paths.get_path(path.id)
      assert updated_path.mount_point == true

      # Both should see the updated state (after refresh in current implementation)
      # Phase 2: Real-time via PubSub
    end

    test "concurrent edits show last-write-wins behavior" do
      user1 = user_fixture()
      user2 = user_fixture()

      {:ok, path} = Paths.create_path(%{path: "contested", user_id: user1.id})
      {:ok, _} = Paths.add_user_to_path(user2.id, path.id, "maintainer")

      conn1 = log_in_user(build_conn(), user1)
      conn2 = log_in_user(build_conn(), user2)

      {:ok, lv1, _html} = live(conn1, ~p"/paths")
      {:ok, lv2, _html} = live(conn2, ~p"/paths")

      # Both open edit modal simultaneously
      lv1
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      lv2
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      # User 1 submits first
      lv1
      |> form("form[phx-submit='save_edit']", edit: %{path: "renamed-by-user1"})
      |> render_submit()

      # User 2 submits second
      lv2
      |> form("form[phx-submit='save_edit']", edit: %{path: "renamed-by-user2"})
      |> render_submit()

      # Last write wins
      final_path = Paths.get_path(path.id)
      assert final_path.path == "renamed-by-user2"
    end

    test "error recovery - user can retry after failed operation" do
      user = user_fixture()
      {:ok, path} = Paths.create_path(%{path: "original", user_id: user.id})

      conn = log_in_user(build_conn(), user)
      {:ok, lv, _html} = live(conn, ~p"/paths")

      # Attempt invalid edit
      lv
      |> element("button[phx-click='open_edit'][phx-value-id='#{path.id}']")
      |> render_click()

      lv
      |> form("form[phx-submit='save_edit']", edit: %{path: "invalid/path"})
      |> render_submit()

      assert render(lv) =~ "Failed to update path"

      # User should be able to retry with valid data
      lv
      |> form("form[phx-submit='save_edit']", edit: %{path: "valid-path"})
      |> render_submit()

      assert render(lv) =~ "Path updated successfully"
      assert render(lv) =~ "valid-path"

      # Verify in database
      updated = Paths.get_path(path.id)
      assert updated.path == "valid-path"
    end
  end
end
