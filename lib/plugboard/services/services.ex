defmodule Plugboard.Services.Services do
  @moduledoc """
  The Services context.
  """
  import Ecto.Query, warn: false
  alias Phoenix.PubSub
  alias Plugboard.Repo
  alias Plugboard.Services.Service
  alias Plugboard.Services.ServiceToken

  @service_token_validity_in_days System.get_env("PHX_SERVICE_TOKEN_VALIDITY_IN_DAYS") |> String.to_integer()

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

  def list_root_services do
    Service.default_scope()
    |> where([service], is_nil(service.parent_id))
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
    result = Plugboard.Repo.transaction(fn ->
      # Update the service and all its descendants with deleted_at
      descendants
      |> Enum.each(fn descendant ->
        Ecto.Changeset.change(descendant, %{deleted_at: now})
        |> Plugboard.Repo.update!()
      end)

      # Update the main service
      updated_service = service
      |> Ecto.Changeset.change(%{deleted_at: now})
      |> Plugboard.Repo.update!()

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

  @doc """
  Creates a new api token for a service.

  The token returned must be saved somewhere safe.
  This token cannot be recovered from the database.
  """
  def create_service_api_token(service) do
    {encoded_token, service_token} = ServiceToken.build_service_token(service, "api-token")
    record = Repo.insert!(service_token)
    token = %{
      id: record.id,
      value: encoded_token,
      context: record.context,
      service_id: record.service_id,
      inserted_at: record.inserted_at,
      expires_at: DateTime.add(record.inserted_at, @service_token_validity_in_days * 24 * 60 * 60, :second)
    }
    PubSub.broadcast(Plugboard.PubSub, "service/#{service.id}", {:token_created, token})
    token
  end

  @doc """
  Fetches the service by API token.
  """
  def fetch_service_by_api_token(token) do
    with {:ok, query} <- ServiceToken.verify_token_query(token, "api-token"),
        {service_token, service} <- Repo.one(query) do
      {:ok, %{service: service, token: service_token}}
    else
      _ -> :error
    end
  end

  defp notify_subscribers({:ok, service}, [:service, :created]) do
    PubSub.broadcast(Plugboard.PubSub, "service/#{service.id}", {:service_created, service})
    if service.parent_id do
      PubSub.broadcast(Plugboard.PubSub, "service/#{service.parent_id}", {:service_created, service})
    else
      PubSub.broadcast(Plugboard.PubSub, "services", {:service_created, service})
    end
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :updated]) do
    PubSub.broadcast(Plugboard.PubSub, "service/#{service.id}", {:service_updated, service})
    PubSub.broadcast(Plugboard.PubSub, "service/#{service.id}", {:path_updated, Service.full_path(service)})
    if service.parent_id do
      PubSub.broadcast(Plugboard.PubSub, "service/#{service.parent_id}", {:service_updated, service})
    else
      PubSub.broadcast(Plugboard.PubSub, "services", {:service_updated, service})
    end
    Service.descendants(service)
    |> Enum.each(fn descendant ->
      PubSub.broadcast(Plugboard.PubSub, "service/#{descendant.id}", {:path_updated, Service.full_path(descendant)})
    end)
    {:ok, service}
  end

  defp notify_subscribers({:ok, service}, [:service, :deleted, descendants, redirect_service_id]) do
    PubSub.broadcast(Plugboard.PubSub, "service/#{service.id}", {:service_deleted, service, redirect_service_id})
    if service.parent_id do
      PubSub.broadcast(Plugboard.PubSub, "service/#{service.parent_id}", {:service_deleted, service, nil})
    else
      PubSub.broadcast(Plugboard.PubSub, "services", {:service_deleted, service})
    end
    descendants
    |> Enum.each(fn descendant ->
      PubSub.broadcast(Plugboard.PubSub, "service/#{descendant.id}", {:service_deleted, descendant, redirect_service_id})
    end)
    {:ok, service}
  end

  defp notify_subscribers({:error, _} = error, _event), do: error
end
