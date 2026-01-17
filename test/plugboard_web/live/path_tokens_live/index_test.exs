defmodule PlugboardWeb.PathTokensLive.IndexTest do
  use PlugboardWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Plugboard.AccountsFixtures

  alias Plugboard.Paths
  alias Plugboard.TelephoneTokens
  alias Plugboard.ServiceAccounts

  defp create_user_and_login(%{conn: conn}) do
    user = user_fixture()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp create_mount_point(user, path_name \\ "api") do
    {:ok, path} =
      Paths.create_path(%{
        path: path_name,
        user_id: user.id
      })

    {:ok, mount_path} = Paths.update_path(user.id, path, %{mount_point: true})
    mount_path
  end

  describe "mount" do
    setup :create_user_and_login

    test "renders tokens page for mount point", %{conn: conn, user: user} do
      mount_path = create_mount_point(user)

      {:ok, _lv, html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      assert html =~ "Tokens"
      assert html =~ "Telephone Tokens"
      assert html =~ "Service Accounts"
    end

    test "redirects if user is not logged in", %{user: user} do
      mount_path = create_mount_point(user)
      conn = build_conn()

      assert {:error, redirect} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      assert {:redirect, %{to: path, flash: flash}} = redirect
      assert path == ~p"/users/log-in"
      assert %{"error" => "You must log in to access this page."} = flash
    end

    test "redirects if path not found", %{conn: conn} do
      fake_id = Ecto.UUID.generate()

      assert {:error, {:redirect, %{to: "/paths", flash: flash}}} =
               live(conn, ~p"/paths/#{fake_id}/tokens")

      assert flash["error"] == "Path not found"
    end

    test "redirects if user does not have access", %{conn: conn, user: _user} do
      other_user = user_fixture()
      mount_path = create_mount_point(other_user)

      assert {:error, {:redirect, %{to: "/paths", flash: flash}}} =
               live(conn, ~p"/paths/#{mount_path.id}/tokens")

      assert flash["error"] == "You do not have access to this path"
    end
  end

  describe "switch_tab" do
    setup :create_user_and_login

    test "switches between tokens and service accounts tabs", %{conn: conn, user: user} do
      mount_path = create_mount_point(user)

      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Default is tokens tab
      assert has_element?(lv, "[data-test='tokens-tab']")
      assert has_element?(lv, "[data-test='token-name-input']")

      # Switch to service accounts
      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      assert has_element?(lv, "[data-test='service-accounts-tab']")
      assert has_element?(lv, "[data-test='service-account-name-input']")

      # Switch back to tokens
      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='tokens']")
      |> render_click()

      assert has_element?(lv, "[data-test='token-name-input']")
    end
  end

  describe "edit telephone token" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)

      {:ok, _jwt, token} =
        TelephoneTokens.generate_token(mount_path, user, "test-token", "test description")

      %{mount_path: mount_path, token: token}
    end

    test "opens edit modal when edit button clicked", %{
      conn: conn,
      mount_path: mount_path,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Click edit button
      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      # Modal should be visible
      assert has_element?(lv, "#edit-token-modal")
      assert has_element?(lv, "input[name='edit_token[name]'][value='test-token']")
      assert has_element?(lv, "input[name='edit_token[description]'][value='test description']")
    end

    test "closes edit modal when cancel clicked", %{
      conn: conn,
      mount_path: mount_path,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Open modal
      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      assert has_element?(lv, "#edit-token-modal")

      # Close modal
      render_click(lv, "close_edit_token")

      refute has_element?(lv, "#edit-token-modal")
    end

    test "successfully updates token name and description", %{
      conn: conn,
      mount_path: mount_path,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Open edit modal
      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      # Submit updated values
      lv
      |> form("#edit-token-modal form",
        edit_token: %{name: "updated-token", description: "updated desc"}
      )
      |> render_submit()

      # Check flash message
      assert render(lv) =~ "Token updated successfully"

      # Modal should close
      refute has_element?(lv, "#edit-token-modal")

      # Verify token was updated
      updated_token = TelephoneTokens.get_token(token.id)
      assert updated_token.name == "updated-token"
      assert updated_token.description == "updated desc"

      # UI should show updated values
      assert render(lv) =~ "updated-token"
      assert render(lv) =~ "updated desc"
    end

    test "updates only name", %{conn: conn, mount_path: mount_path, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      lv
      |> form("#edit-token-modal form",
        edit_token: %{name: "only-name-updated", description: "test description"}
      )
      |> render_submit()

      updated_token = TelephoneTokens.get_token(token.id)
      assert updated_token.name == "only-name-updated"
      assert updated_token.description == "test description"
    end

    test "allows clearing name and description", %{
      conn: conn,
      mount_path: mount_path,
      token: token
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      lv
      |> form("#edit-token-modal form", edit_token: %{name: "", description: ""})
      |> render_submit()

      updated_token = TelephoneTokens.get_token(token.id)
      assert updated_token.name == nil
      assert updated_token.description == nil

      # Should show "Unnamed token" in UI
      assert render(lv) =~ "Unnamed token"
    end

    test "shows error for token not found", %{conn: conn, mount_path: mount_path} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      fake_id = Ecto.UUID.generate()

      # Trigger the event directly
      render_click(lv, "open_edit_token", %{"id" => fake_id})

      assert render(lv) =~ "Token not found"
    end

    test "viewer role cannot edit token", %{user: owner, mount_path: mount_path, token: token} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      lv
      |> form("#edit-token-modal form", edit_token: %{name: "hacked", description: "hacked"})
      |> render_submit()

      assert render(lv) =~ "Requires owner or maintainer role"

      # Token should not be updated
      unchanged_token = TelephoneTokens.get_token(token.id)
      assert unchanged_token.name == "test-token"
      assert unchanged_token.description == "test description"
    end

    test "maintainer role can edit token", %{user: owner, mount_path: mount_path, token: token} do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, maintainer.id, mount_path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='open_edit_token'][phx-value-id='#{token.id}']")
      |> render_click()

      lv
      |> form("#edit-token-modal form",
        edit_token: %{name: "maintainer-updated", description: "by maintainer"}
      )
      |> render_submit()

      assert render(lv) =~ "Token updated successfully"

      updated_token = TelephoneTokens.get_token(token.id)
      assert updated_token.name == "maintainer-updated"
      assert updated_token.description == "by maintainer"
    end
  end

  describe "edit service account" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)

      {:ok, _api_key, service_account} =
        ServiceAccounts.generate_service_account(
          user,
          mount_path.id,
          "test-sa",
          "test description"
        )

      %{mount_path: mount_path, service_account: service_account}
    end

    test "opens edit modal when edit button clicked", %{
      conn: conn,
      mount_path: mount_path,
      service_account: sa
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Switch to service accounts tab
      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      # Click edit button
      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      # Modal should be visible
      assert has_element?(lv, "#edit-service-account-modal")
      assert has_element?(lv, "input[name='edit_service_account[name]'][value='test-sa']")

      assert has_element?(
               lv,
               "input[name='edit_service_account[description]'][value='test description']"
             )
    end

    test "closes edit modal when cancel clicked", %{
      conn: conn,
      mount_path: mount_path,
      service_account: sa
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      assert has_element?(lv, "#edit-service-account-modal")

      # Close modal
      render_click(lv, "close_edit_service_account")

      refute has_element?(lv, "#edit-service-account-modal")
    end

    test "successfully updates service account name and description", %{
      conn: conn,
      mount_path: mount_path,
      service_account: sa
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      # Submit updated values
      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "updated-sa", description: "updated desc"}
      )
      |> render_submit()

      # Check flash message
      assert render(lv) =~ "Service account updated successfully"

      # Modal should close
      refute has_element?(lv, "#edit-service-account-modal")

      # Verify service account was updated
      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.name == "updated-sa"
      assert updated_sa.description == "updated desc"

      # UI should show updated values
      assert render(lv) =~ "updated-sa"
      assert render(lv) =~ "updated desc"
    end

    test "updates only name", %{conn: conn, mount_path: mount_path, service_account: sa} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "only-name-updated", description: "test description"}
      )
      |> render_submit()

      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.name == "only-name-updated"
      assert updated_sa.description == "test description"
    end

    test "allows clearing description", %{conn: conn, mount_path: mount_path, service_account: sa} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "test-sa", description: ""}
      )
      |> render_submit()

      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.name == "test-sa"
      assert updated_sa.description == nil
    end

    test "validates name format", %{conn: conn, mount_path: mount_path, service_account: sa} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "invalid name!", description: ""}
      )
      |> render_submit()

      assert render(lv) =~ "Failed to update service account"
    end

    test "validates name length", %{conn: conn, mount_path: mount_path, service_account: sa} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      # Too short
      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "ab", description: ""}
      )
      |> render_submit()

      assert render(lv) =~ "Failed to update service account"
    end

    test "shows error for service account not found", %{conn: conn, mount_path: mount_path} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      fake_id = Ecto.UUID.generate()

      # Trigger the event directly
      render_click(lv, "open_edit_service_account", %{"id" => fake_id})

      assert render(lv) =~ "Service account not found"
    end

    test "viewer role cannot edit service account", %{
      user: owner,
      mount_path: mount_path,
      service_account: sa
    } do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "hacked", description: "hacked"}
      )
      |> render_submit()

      assert render(lv) =~ "Requires owner or maintainer role"

      # Service account should not be updated
      unchanged_sa = ServiceAccounts.get_service_account(sa.id)
      assert unchanged_sa.name == "test-sa"
      assert unchanged_sa.description == "test description"
    end

    test "maintainer role can edit service account", %{
      user: owner,
      mount_path: mount_path,
      service_account: sa
    } do
      maintainer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, maintainer.id, mount_path.id, "maintainer")

      conn = log_in_user(build_conn(), maintainer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "maintainer-updated", description: "by maintainer"}
      )
      |> render_submit()

      assert render(lv) =~ "Service account updated successfully"

      updated_sa = ServiceAccounts.get_service_account(sa.id)
      assert updated_sa.name == "maintainer-updated"
      assert updated_sa.description == "by maintainer"
    end

    test "enforces unique name per user", %{
      conn: conn,
      user: user,
      mount_path: mount_path,
      service_account: sa
    } do
      # Create another service account
      {:ok, _, _sa2} =
        ServiceAccounts.generate_service_account(user, mount_path.id, "other-sa", nil)

      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='open_edit_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      # Try to use the other service account's name
      lv
      |> form("#edit-service-account-modal form",
        edit_service_account: %{name: "other-sa", description: ""}
      )
      |> render_submit()

      assert render(lv) =~ "Failed to update service account"

      # Original service account should be unchanged
      unchanged_sa = ServiceAccounts.get_service_account(sa.id)
      assert unchanged_sa.name == "test-sa"
    end
  end

  describe "create telephone token" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)
      %{mount_path: mount_path}
    end

    test "creates token successfully", %{conn: conn, mount_path: mount_path} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Submit token creation form
      lv
      |> form("form[phx-submit='create_token']",
        token: %{name: "new-token", description: "new token description"}
      )
      |> render_submit()

      # Should show success message
      assert render(lv) =~ "Token created successfully"

      # Token created modal should appear with the JWT
      assert has_element?(lv, "#token-created-modal")

      # Close the modal
      render_click(lv, "close_token_modal")
      refute has_element?(lv, "#token-created-modal")

      # Token should appear in the list
      assert render(lv) =~ "new-token"
    end

    test "creates token with empty name and description", %{conn: conn, mount_path: mount_path} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> form("form[phx-submit='create_token']", token: %{name: "", description: ""})
      |> render_submit()

      assert render(lv) =~ "Token created successfully"

      # Should show "Unnamed token" in the list
      assert render(lv) =~ "Unnamed token"
    end

    test "viewer cannot create token", %{user: owner, mount_path: mount_path} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> form("form[phx-submit='create_token']", token: %{name: "hack", description: ""})
      |> render_submit()

      assert render(lv) =~ "Requires owner or maintainer role"
    end
  end

  describe "revoke telephone token" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)

      {:ok, _jwt, token} =
        TelephoneTokens.generate_token(mount_path, user, "to-revoke", nil)

      %{mount_path: mount_path, token: token}
    end

    test "revokes token successfully", %{conn: conn, mount_path: mount_path, token: token} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Verify token is displayed
      assert render(lv) =~ "to-revoke"

      # Revoke the token
      lv
      |> element("button[phx-click='revoke_token'][phx-value-id='#{token.id}']")
      |> render_click()

      assert render(lv) =~ "Token revoked successfully"

      # Token should no longer appear (or should show as revoked)
      refute render(lv) =~ "to-revoke"
    end

    test "viewer cannot revoke token", %{user: owner, mount_path: mount_path, token: token} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='revoke_token'][phx-value-id='#{token.id}']")
      |> render_click()

      assert render(lv) =~ "Requires owner or maintainer role"

      # Token should still exist
      assert TelephoneTokens.get_token(token.id) != nil
    end
  end

  describe "create service account" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)
      %{mount_path: mount_path}
    end

    test "creates service account successfully", %{conn: conn, mount_path: mount_path} do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      # Switch to service accounts tab
      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      # Submit service account creation form
      lv
      |> form("form[phx-submit='create_service_account']",
        service_account: %{name: "new-sa", description: "new sa description"}
      )
      |> render_submit()

      # Should show success message
      assert render(lv) =~ "Service account created successfully"

      # API key modal should appear
      assert has_element?(lv, "#api-key-created-modal")

      # Close the modal
      render_click(lv, "close_api_key_modal")
      refute has_element?(lv, "#api-key-created-modal")

      # Service account should appear in the list
      assert render(lv) =~ "new-sa"
    end

    test "viewer cannot create service account", %{user: owner, mount_path: mount_path} do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> form("form[phx-submit='create_service_account']",
        service_account: %{name: "hack", description: ""}
      )
      |> render_submit()

      assert render(lv) =~ "Requires owner or maintainer role"
    end
  end

  describe "revoke service account" do
    setup :create_user_and_login

    setup %{user: user} do
      mount_path = create_mount_point(user)

      {:ok, _api_key, service_account} =
        ServiceAccounts.generate_service_account(user, mount_path.id, "to-revoke-sa", nil)

      %{mount_path: mount_path, service_account: service_account}
    end

    test "revokes service account successfully", %{
      conn: conn,
      mount_path: mount_path,
      service_account: sa
    } do
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      # Verify service account is displayed
      assert render(lv) =~ "to-revoke-sa"

      # Revoke the service account
      lv
      |> element("button[phx-click='revoke_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      assert render(lv) =~ "Service account revoked successfully"

      # Service account should no longer appear
      refute render(lv) =~ "to-revoke-sa"
    end

    test "viewer cannot revoke service account", %{
      user: owner,
      mount_path: mount_path,
      service_account: sa
    } do
      viewer = user_fixture()
      {:ok, _} = Paths.add_user_to_path(owner.id, viewer.id, mount_path.id, "viewer")

      conn = log_in_user(build_conn(), viewer)
      {:ok, lv, _html} = live(conn, ~p"/paths/#{mount_path.id}/tokens")

      lv
      |> element("button[phx-click='switch_tab'][phx-value-tab='service_accounts']")
      |> render_click()

      lv
      |> element("button[phx-click='revoke_service_account'][phx-value-id='#{sa.id}']")
      |> render_click()

      assert render(lv) =~ "Requires owner or maintainer role"

      # Service account should still exist
      assert ServiceAccounts.get_service_account(sa.id) != nil
    end
  end
end
