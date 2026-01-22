defmodule PlugboardWeb.PageController do
  use PlugboardWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
