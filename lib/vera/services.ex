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
    Service.default_scope()
    |> Repo.all()
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
  def get_service!(id) do
    Service.default_scope()
    |> Repo.get!(id)
  end

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
  Deletes a service and all its descendants.

  ## Examples

      iex> delete_service(service)
      {:ok, %Service{}}

      iex> delete_service(service)
      {:error, %Ecto.Changeset{}}

  """
  def delete_service(%Service{} = service) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # Get all descendants first
    descendants = Service.descendants(service)

    # Start a transaction to update all records
    result = Vera.Repo.transaction(fn ->
      # Update the service and all its descendants with deleted_at
      descendants
      |> Enum.each(fn descendant ->
        Ecto.Changeset.change(descendant, %{deleted_at: now})
        |> Vera.Repo.update!()
      end)

      # Update the main service
      updated_service = service
      |> Ecto.Changeset.change(%{deleted_at: now})
      |> Vera.Repo.update!()

      {updated_service, descendants}
    end)

    case result do
      {:ok, {updated_service, descendants}} ->
        notify_subscribers({:ok, updated_service}, [:service, :deleted, descendants, service.parent_id])
      error ->
        error
    end
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
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.id}", {:service_created, service})
    if service.parent_id do
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.parent_id}", {:service_created, service})
    else
      Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_created, service})
    end
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :updated]) do
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.id}", {:service_updated, service})
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.id}", {:path_updated, Service.full_path(service)})
    if service.parent_id do
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.parent_id}", {:service_updated, service})
    else
      Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_updated, service})
    end
    Service.descendants(service)
    |> Enum.each(fn descendant ->
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{descendant.id}", {:path_updated, Service.full_path(descendant)})
    end)
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :deleted, descendants, redirect_service_id]) do
    Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{service.id}", {:service_deleted, service, redirect_service_id})
    if service.parent_id == nil do
      Phoenix.PubSub.broadcast(Vera.PubSub, "services", {:service_deleted, service})
    end
    descendants
    |> Enum.each(fn descendant ->
      Phoenix.PubSub.broadcast(Vera.PubSub, "service/#{descendant.id}", {:service_deleted, descendant, redirect_service_id})
    end)
    {:ok, service}
  end

  defp notify_subscribers({:error, _} = error, _event), do: error
end
