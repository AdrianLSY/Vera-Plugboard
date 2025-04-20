defmodule PlugboardWeb.AccountForgotPasswordLiveTest do
  use PlugboardWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Plugboard.AccountsFixtures

  alias Plugboard.Repo
  alias Plugboard.Accounts.AccountToken

  describe "Forgot password page" do
    test "renders email page", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/reset_password")

      assert html =~ "Forgot your password?"
      assert has_element?(lv, ~s|a[href="#{~p"/register"}"]|, "Register")
      assert has_element?(lv, ~s|a[href="#{~p"/login"}"]|, "Log in")
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> login_account(account_fixture())
        |> live(~p"/reset_password")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end
  end

  describe "Reset link" do
    setup do
      %{account: account_fixture()}
    end

    test "sends a new reset password token", %{conn: conn, account: account} do
      {:ok, lv, _html} = live(conn, ~p"/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", account: %{"email" => account.email})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"

      assert Repo.get_by!(AccountToken, account_id: account.id).context ==
               "reset_password"
    end

    test "does not send reset password token if email is invalid", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/reset_password")

      {:ok, conn} =
        lv
        |> form("#reset_password_form", account: %{"email" => "unknown@example.com"})
        |> render_submit()
        |> follow_redirect(conn, "/")

      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "If your email is in our system"
      assert Repo.all(AccountToken) == []
    end
  end
end
