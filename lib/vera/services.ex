defmodule Vera.Services do
  @moduledoc """
  The Services context.
  """

  import Ecto.Query, warn: false
  alias Vera.Repo

  alias Vera.Services.Service

  @doc """
  Returns the list of services.

  ## Examples

      iex> list_services()
      [%Service{}, ...]

  """
  def list_services do
    Repo.all(Service)
  end

  @doc """
  Gets a single service.

  Raises `Ecto.NoResultsError` if the Service does not exist.

  ## Examples

      iex> get_service!(123)
      %Service{}

      iex> get_service!(456)
      ** (Ecto.NoResultsError)

  """
  def get_service!(id), do: Repo.get!(Service, id)

  @doc """
  Creates a service.

  Also broadcasts a `:service_created` message to all LiveViews subscribed
  to the `"services"` topic.

  ## Examples

      iex> create_service(%{name: "New Service"})
      {:ok, %Service{}}

      iex> create_service(%{name: nil})
      {:error, %Ecto.Changeset{}}
  """
  def create_service(attrs \\ %{}) do
    %Service{}
    |> Service.changeset(attrs)
    |> Repo.insert()
    |> notify_subscribers([:service, :created])
  end

  @doc """
  Updates a service.

  ## Examples

      iex> update_service(service, %{field: new_value})
      {:ok, %Service{}}

      iex> update_service(service, %{field: bad_value})
      {:error, %Ecto.Changeset{}}

  """
  def update_service(%Service{} = service, attrs) do
    service
    |> Service.changeset(attrs)
    |> Repo.update()
    |> notify_subscribers([:service, :updated])
  end

  @doc """
  Deletes a service.

  ## Examples

      iex> delete_service(service)
      {:ok, %Service{}}

      iex> delete_service(service)
      {:error, %Ecto.Changeset{}}

  """
  def delete_service(%Service{} = service) do
    Repo.delete(service)
    |> notify_subscribers([:service, :deleted])
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking service changes.

  ## Examples

      iex> change_service(service)
      %Ecto.Changeset{data: %Service{}}

  """
  def change_service(%Service{} = service, attrs \\ %{}) do
    Service.changeset(service, attrs)
  end

  defp notify_subscribers({:ok, service}, [:service, :created]) do
    Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_created, service})
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :updated]) do
    Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_updated, service})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service_#{service.id}", {:service_updated, service})
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :deleted]) do
    Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_deleted, service})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service_#{service.id}", {:service_deleted, service})
    {:ok, service}
  end

  defp notify_subscribers({:error, _} = error, _event), do: error
end
