defmodule VeraWeb.AccountSessionControllerTest do
  use VeraWeb.ConnCase, async: true

  import Vera.AccountsFixtures

  setup do
    %{account: account_fixture()}
  end

  describe "POST /login" do
    test "logs the account in", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => account.email, "password" => valid_account_password()}
        })

      assert get_session(conn, :account_token)
      assert redirected_to(conn) == ~p"/"

      # Now do a logged in request and assert on the menu
      conn = get(conn, ~p"/")
      response = html_response(conn, 200)
      assert response =~ account.email
      assert response =~ ~p"/settings"
      assert response =~ ~p"/log_out"
    end

    test "logs the account in with remember me", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password(),
            "remember_me" => "true"
          }
        })

      assert conn.resp_cookies["_vera_web_account_remember_me"]
      assert redirected_to(conn) == ~p"/"
    end

    test "logs the account in with return to", %{conn: conn, account: account} do
      conn =
        conn
        |> init_test_session(account_return_to: "/foo/bar")
        |> post(~p"/login", %{
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password()
          }
        })

      assert redirected_to(conn) == "/foo/bar"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Welcome back!"
    end

    test "login following registration", %{conn: conn, account: account} do
      conn =
        conn
        |> post(~p"/login", %{
          "_action" => "registered",
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password()
          }
        })

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Account created successfully"
    end

    test "login following password update", %{conn: conn, account: account} do
      conn =
        conn
        |> post(~p"/login", %{
          "_action" => "password_updated",
          "account" => %{
            "email" => account.email,
            "password" => valid_account_password()
          }
        })

      assert redirected_to(conn) == ~p"/settings"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Password updated successfully"
    end

    test "redirects to login page with invalid credentials", %{conn: conn} do
      conn =
        post(conn, ~p"/login", %{
          "account" => %{"email" => "invalid@email.com", "password" => "invalid_password"}
        })

      assert Phoenix.Flash.get(conn.assigns.flash, :error) == "Invalid email or password"
      assert redirected_to(conn) == ~p"/login"
    end
  end

  describe "DELETE /log_out" do
    test "logs the account out", %{conn: conn, account: account} do
      conn = conn |> login_account(account) |> delete(~p"/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end

    test "succeeds even if the account is not logged in", %{conn: conn} do
      conn = delete(conn, ~p"/log_out")
      assert redirected_to(conn) == ~p"/"
      refute get_session(conn, :account_token)
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out successfully"
    end
  end
end
