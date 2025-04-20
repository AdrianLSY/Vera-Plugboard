defmodule Vera.ServicesFixtures do
  @moduledoc """
  This module defines test helpers for creating
  entities via the `Vera.Services` context.
  """

  @doc """
  Generate a service.
  """

  def service_fixture(attrs \\ %{}) do
    {:ok, service} =
      attrs
      |> Enum.into(%{
        name: "some name#{System.unique_integer()}"
      })
      |> Vera.Services.Services.create_service()

    service
  end
end
