defmodule Vera.Services.ServiceToken do
  use Ecto.Schema
  import Ecto.Query
  alias Vera.Services.ServiceToken

  @hash_algorithm :sha256
  @rand_size 32
  @service_token_validity_in_days System.get_env("PHX_SERVICE_TOKEN_VALIDITY_IN_DAYS") |> String.to_integer()
  @derive {Jason.Encoder, only: [:id, :context, :service_id, :inserted_at]}

  schema "services_tokens" do
    field :token, :binary
    field :context, :string
    belongs_to :service, Vera.Services.Service

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @doc """
  Creates a changeset for a new service token.
  """
  def changeset(token, attrs) do
    token
    |> Ecto.Changeset.cast(attrs, [:service_id])
    |> Ecto.Changeset.validate_required([:service_id])
  end

  @doc """
  Builds a token and its hash for a service

  The hashed token is stored in the database. The original token cannot be reconstructed,
  which means anyone with read-only access to the database cannot directly use
  the token in the application to gain access.
  """
  def build_service_token(service, context) do
    build_hashed_token(service, context)
  end

  defp build_hashed_token(service, context) do
    token = :crypto.strong_rand_bytes(@rand_size)
    hashed_token = :crypto.hash(@hash_algorithm, token)

    {Base.url_encode64(token, padding: false),
     %ServiceToken{
       token: hashed_token,
       context: context,
       service_id: service.id
     }}
  end

  @doc """
  Checks if the token is valid and returns its underlying lookup query.

  The query returns the service found by the token, if any.

  The given token is valid if it matches its hashed counterpart in the
  database. The token is valid if it matches the value in the database
  and it has not expired.
  """
  def verify_token_query(token, context) do
    case Base.url_decode64(token, padding: false) do
      {:ok, decoded_token} ->
        hashed_token = :crypto.hash(@hash_algorithm, decoded_token)
        days = days_for_context(context)

        query =
          from token in by_token_and_context_query(hashed_token, context),
            join: service in assoc(token, :service),
            where: token.inserted_at > ago(^days, "day"),
            select: service

        {:ok, query}

      :error ->
        :error
    end
  end

  defp days_for_context("api-token"), do: @service_token_validity_in_days

  @doc """
  Returns the token struct for the given token value and context.
  """
  def by_token_and_context_query(token, context) do
    from ServiceToken, where: [token: ^token, context: ^context]
  end

  @doc """
  Gets all tokens for the given service for the given contexts.
  """
  def by_service_and_contexts_query(service, :all) do
    from t in ServiceToken, where: t.service_id == ^service.id
  end

  def by_service_and_contexts_query(service, [_ | _] = contexts) do
    from t in ServiceToken, where: t.service_id == ^service.id and t.context in ^contexts
  end

  @doc """
  Returns all valid API tokens for a given service.

  Only returns tokens that haven't expired based on @service_token_validity_in_days.
  """
  def list_valid_api_tokens(service) do
    from(t in ServiceToken,
      where: t.service_id == ^service.id and
             t.context == "api-token" and
             t.inserted_at > ago(@service_token_validity_in_days, "day"))
  end

  @doc """
  Deletes a specific token from the database.

  This can be used to revoke API access for a specific token.
  """
  def delete_token(token_id) do
    Vera.Repo.delete(%ServiceToken{id: token_id})
  end

  @doc """
  Deletes all tokens with the given context for a specific service.

  This can be used to revoke all API access for a service.
  """
  def delete_all_tokens_for_service(service, context) do
    query = from(t in ServiceToken,
      where: t.service_id == ^service.id and
        t.context == ^context)

    Vera.Repo.delete_all(query)
  end
end
