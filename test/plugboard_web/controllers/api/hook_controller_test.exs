defmodule PlugboardWeb.Api.HookControllerTest do
  use PlugboardWeb.ConnCase, async: true

  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.Hooks

  setup %{conn: conn} do
    user = user_fixture()

    # Log in the user
    conn = log_in_user(conn, user)

    # Create a path owned by this user
    {:ok, path} =
      Paths.create_path(%{
        path: "api",
        user_id: user.id
      })

    # Create a mount point as target for hooks
    {:ok, target} =
      Paths.create_path(%{
        path: "auth",
        user_id: user.id
      })

    {:ok, target_mount} = Paths.update_path(user.id, target, %{mount_point: true})

    %{conn: conn, user: user, path: path, target: target_mount}
  end

  describe "POST /api/paths/:path_id/hooks" do
    test "creates hook with owner role", %{conn: conn, path: path, target: target} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "Test Hook",
          "description" => "A test hook",
          "target_type" => "mount_point",
          "target_path_id" => target.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 201)
      assert json["id"] != nil
      assert json["name"] == "Test Hook"
      assert json["description"] == "A test hook"
      assert json["target_type"] == "mount_point"
      assert json["target_path_id"] == target.id
      assert json["execution_order"] == 0
      assert json["timeout_ms"] == 5000
    end

    test "creates http_url hook", %{conn: conn, path: path} do
      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "External Hook",
          "target_type" => "http_url",
          "target_url" => "https://example.com/webhook",
          "execution_order" => 0,
          "timeout_ms" => 3000
        })

      assert json = json_response(conn, 201)
      assert json["name"] == "External Hook"
      assert json["target_type"] == "http_url"
      assert json["target_url"] == "https://example.com/webhook"
    end

    test "creates hook with maintainer role", %{user: user, path: path, target: target} do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)

      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "Maintainer Hook",
          "target_type" => "mount_point",
          "target_path_id" => target.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 201)
      assert json["name"] == "Maintainer Hook"
    end

    test "rejects creation with viewer role", %{user: user, path: path, target: target} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)

      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "Viewer Hook",
          "target_type" => "mount_point",
          "target_path_id" => target.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 403)
      assert json["error"] == "Requires owner or maintainer role"
    end

    test "rejects creation when user has no access", %{path: path, target: target} do
      other_user = user_fixture()
      conn = log_in_user(build_conn(), other_user)

      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "Unauthorized Hook",
          "target_type" => "mount_point",
          "target_path_id" => target.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 403)
      assert json["error"] == "You do not have access to this path"
    end

    test "returns 404 for non-existent path", %{conn: conn, target: target} do
      fake_id = Ecto.UUID.generate()

      conn =
        post(conn, ~p"/api/paths/#{fake_id}/hooks", %{
          "name" => "Test Hook",
          "target_type" => "mount_point",
          "target_path_id" => target.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 404)
      assert json["error"] == "Path not found"
    end

    test "validates required fields", %{conn: conn, path: path} do
      conn = post(conn, ~p"/api/paths/#{path.id}/hooks", %{})

      assert json = json_response(conn, 422)
      assert json["error"] == "Failed to create hook"
      assert json["details"]["name"] != nil
    end

    test "rejects invalid target_path (not a mount point)", %{conn: conn, path: path, user: user} do
      # Create a non-mount path
      {:ok, non_mount} =
        Paths.create_path(%{
          path: "nonmount",
          user_id: user.id
        })

      conn =
        post(conn, ~p"/api/paths/#{path.id}/hooks", %{
          "name" => "Invalid Hook",
          "target_type" => "mount_point",
          "target_path_id" => non_mount.id,
          "execution_order" => 0,
          "timeout_ms" => 5000
        })

      assert json = json_response(conn, 403)
      assert json["error"] == "Target path must be a mount point"
    end
  end

  describe "GET /api/paths/:path_id/hooks" do
    test "lists hooks for path", %{conn: conn, user: user, path: path, target: target} do
      # Create some hooks
      {:ok, _hook1} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Hook 1",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      {:ok, _hook2} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Hook 2",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 1,
          timeout_ms: 5000
        })

      conn = get(conn, ~p"/api/paths/#{path.id}/hooks")

      assert json = json_response(conn, 200)
      assert length(json["hooks"]) == 2
      assert Enum.at(json["hooks"], 0)["name"] == "Hook 1"
      assert Enum.at(json["hooks"], 1)["name"] == "Hook 2"
    end

    test "returns empty list when no hooks", %{conn: conn, path: path} do
      conn = get(conn, ~p"/api/paths/#{path.id}/hooks")

      assert json = json_response(conn, 200)
      assert json["hooks"] == []
    end

    test "allows viewer to list hooks", %{user: user, path: path, target: target} do
      # Create a hook
      {:ok, _hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Test Hook",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      conn = get(conn, ~p"/api/paths/#{path.id}/hooks")

      assert json = json_response(conn, 200)
      assert length(json["hooks"]) == 1
    end

    test "rejects when user has no access", %{path: path} do
      other_user = user_fixture()
      conn = log_in_user(build_conn(), other_user)

      conn = get(conn, ~p"/api/paths/#{path.id}/hooks")

      assert json = json_response(conn, 403)
      assert json["error"] == "You do not have access to this path"
    end
  end

  describe "GET /api/hooks/:id" do
    setup %{user: user, path: path, target: target} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Test Hook",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      %{hook: hook}
    end

    test "returns hook details", %{conn: conn, hook: hook, target: target} do
      conn = get(conn, ~p"/api/hooks/#{hook.id}")

      assert json = json_response(conn, 200)
      assert json["id"] == hook.id
      assert json["name"] == "Test Hook"
      assert json["target_type"] == "mount_point"
      assert json["target_path_id"] == target.id
      assert json["target_path"] == "/auth"
    end

    test "returns 404 for non-existent hook", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = get(conn, ~p"/api/hooks/#{fake_id}")

      assert json = json_response(conn, 404)
      assert json["error"] == "Hook not found"
    end

    test "rejects when user has no access", %{hook: hook} do
      other_user = user_fixture()
      conn = log_in_user(build_conn(), other_user)

      conn = get(conn, ~p"/api/hooks/#{hook.id}")

      assert json = json_response(conn, 403)
      assert json["error"] == "You do not have access to this hook"
    end
  end

  describe "PUT /api/hooks/:id" do
    setup %{user: user, path: path, target: target} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Original Hook",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      %{hook: hook}
    end

    test "updates hook with owner role", %{conn: conn, hook: hook} do
      conn =
        put(conn, ~p"/api/hooks/#{hook.id}", %{
          "name" => "Updated Hook",
          "timeout_ms" => 10_000
        })

      assert json = json_response(conn, 200)
      assert json["name"] == "Updated Hook"
      assert json["timeout_ms"] == 10_000
    end

    test "updates hook with maintainer role", %{user: user, path: path, hook: hook} do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)

      conn =
        put(conn, ~p"/api/hooks/#{hook.id}", %{
          "name" => "Maintainer Update"
        })

      assert json = json_response(conn, 200)
      assert json["name"] == "Maintainer Update"
    end

    test "rejects update with viewer role", %{user: user, path: path, hook: hook} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)

      conn =
        put(conn, ~p"/api/hooks/#{hook.id}", %{
          "name" => "Viewer Update"
        })

      assert json = json_response(conn, 403)
      assert json["error"] == "Requires owner or maintainer role"
    end

    test "returns 404 for non-existent hook", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      conn =
        put(conn, ~p"/api/hooks/#{fake_id}", %{
          "name" => "Update"
        })

      assert json = json_response(conn, 404)
      assert json["error"] == "Hook not found"
    end

    test "validates updated fields", %{conn: conn, hook: hook} do
      conn =
        put(conn, ~p"/api/hooks/#{hook.id}", %{
          "timeout_ms" => -1
        })

      assert json = json_response(conn, 422)
      assert json["error"] == "Failed to update hook"
    end
  end

  describe "DELETE /api/hooks/:id" do
    setup %{user: user, path: path, target: target} do
      {:ok, hook} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Test Hook",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      %{hook: hook}
    end

    test "deletes hook with owner role", %{conn: conn, hook: hook} do
      conn = delete(conn, ~p"/api/hooks/#{hook.id}")

      assert json = json_response(conn, 200)
      assert json["message"] == "Hook deleted successfully"

      # Verify hook is deleted
      assert Hooks.get_hook(hook.id) == nil
    end

    test "deletes hook with maintainer role", %{user: user, path: path, hook: hook} do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, maintainer.id, path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)
      conn = delete(conn, ~p"/api/hooks/#{hook.id}")

      assert json = json_response(conn, 200)
      assert json["message"] == "Hook deleted successfully"
    end

    test "rejects deletion with viewer role", %{user: user, path: path, hook: hook} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      conn = delete(conn, ~p"/api/hooks/#{hook.id}")

      assert json = json_response(conn, 403)
      assert json["error"] == "Requires owner or maintainer role"
    end

    test "returns 404 for non-existent hook", %{conn: conn} do
      fake_id = Ecto.UUID.generate()
      conn = delete(conn, ~p"/api/hooks/#{fake_id}")

      assert json = json_response(conn, 404)
      assert json["error"] == "Hook not found"
    end
  end

  describe "PATCH /api/paths/:path_id/hooks/reorder" do
    setup %{user: user, path: path, target: target} do
      {:ok, hook0} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Hook A",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      {:ok, hook1} =
        Hooks.create_hook(user.id, %{
          path_id: path.id,
          name: "Hook B",
          target_type: "mount_point",
          target_path_id: target.id,
          execution_order: 1,
          timeout_ms: 5000
        })

      %{hooks: [hook0, hook1]}
    end

    test "reorders hooks", %{conn: conn, path: path, hooks: [hook0, hook1]} do
      conn =
        patch(conn, ~p"/api/paths/#{path.id}/hooks/reorder", %{
          "hooks" => [
            %{"id" => hook1.id, "execution_order" => 10},
            %{"id" => hook0.id, "execution_order" => 20}
          ]
        })

      assert json = json_response(conn, 200)
      assert length(json["hooks"]) == 2

      # Verify new order
      hooks = Hooks.list_hooks_for_path(path.id)
      assert Enum.at(hooks, 0).id == hook1.id
      assert Enum.at(hooks, 1).id == hook0.id
    end

    test "rejects reorder with viewer role", %{user: user, path: path, hooks: [hook0, hook1]} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(user.id, viewer.id, path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)

      conn =
        patch(conn, ~p"/api/paths/#{path.id}/hooks/reorder", %{
          "hooks" => [
            %{"id" => hook1.id, "execution_order" => 0},
            %{"id" => hook0.id, "execution_order" => 1}
          ]
        })

      assert json = json_response(conn, 422)
      assert json["error"] == "Requires owner or maintainer role"
    end

    test "validates all hook IDs belong to path", %{
      conn: conn,
      user: user,
      path: path,
      hooks: [hook0, _]
    } do
      # Create another path with a hook
      {:ok, other_path} =
        Paths.create_path(%{
          path: "other",
          user_id: user.id
        })

      {:ok, other_target} =
        Paths.create_path(%{
          path: "other-target",
          user_id: user.id
        })

      {:ok, other_mount} = Paths.update_path(user.id, other_target, %{mount_point: true})

      {:ok, other_hook} =
        Hooks.create_hook(user.id, %{
          path_id: other_path.id,
          name: "Other Hook",
          target_type: "mount_point",
          target_path_id: other_mount.id,
          execution_order: 0,
          timeout_ms: 5000
        })

      conn =
        patch(conn, ~p"/api/paths/#{path.id}/hooks/reorder", %{
          "hooks" => [
            %{"id" => hook0.id, "execution_order" => 0},
            %{"id" => other_hook.id, "execution_order" => 1}
          ]
        })

      assert json = json_response(conn, 422)
      assert json["error"] == "Some hooks not found or do not belong to this path"
    end
  end
end
