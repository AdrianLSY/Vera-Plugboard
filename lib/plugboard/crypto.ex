defmodule Plugboard.Crypto do
  @moduledoc """
  Cryptographic utilities for secure token and API key handling.

  Provides functions for:
  - Secure token/key hashing using Argon2
  - JWT signing key derivation
  - Constant-time comparison for security-sensitive operations

  ## Security Notes

  - All tokens and API keys are hashed using Argon2 before storage
  - The original token/key is never stored and cannot be recovered
  - JWT signing keys are derived from the application secret using HMAC
  - All comparisons use constant-time algorithms to prevent timing attacks
  """

  @doc """
  Hashes a token or API key using Argon2.

  Returns a hash string that can be safely stored in the database.
  The hash includes a random salt, making each hash unique even for
  identical inputs.

  ## Examples

      iex> hash = Plugboard.Crypto.hash_token("my_secret_token")
      iex> String.starts_with?(hash, "$argon2")
      true
  """
  @spec hash_token(String.t()) :: String.t()
  def hash_token(token) when is_binary(token) do
    Argon2.hash_pwd_salt(token)
  end

  @doc """
  Verifies a token against its stored hash.

  Uses constant-time comparison to prevent timing attacks.

  ## Examples

      iex> hash = Plugboard.Crypto.hash_token("my_secret_token")
      iex> Plugboard.Crypto.verify_token("my_secret_token", hash)
      true
      iex> Plugboard.Crypto.verify_token("wrong_token", hash)
      false
  """
  @spec verify_token(String.t(), String.t()) :: boolean()
  def verify_token(token, hash) when is_binary(token) and is_binary(hash) do
    Argon2.verify_pass(token, hash)
  end

  def verify_token(_, _), do: false

  @doc """
  Derives a JWT signing key from the application secret.

  Uses HMAC-SHA256 to derive a separate key specifically for JWT signing,
  ensuring that compromise of the JWT key doesn't compromise other
  uses of the secret_key_base.

  ## Parameters

    - `purpose` - A string identifying the purpose of the key (e.g., "telephone_jwt")

  ## Examples

      iex> key = Plugboard.Crypto.derive_jwt_secret("telephone_jwt")
      iex> is_binary(key) and byte_size(key) > 32
      true
  """
  @spec derive_jwt_secret(String.t()) :: String.t()
  def derive_jwt_secret(purpose) when is_binary(purpose) do
    secret_key_base = get_secret_key_base!()

    :crypto.mac(:hmac, :sha256, secret_key_base, "plugboard_#{purpose}_v1")
    |> Base.encode64()
  end

  @doc """
  Legacy SHA256 hash function for backward compatibility.

  **DEPRECATED**: Use `hash_token/1` for new tokens.

  This function is kept only for verifying legacy tokens during
  a migration period. New code should use Argon2-based hashing.
  """
  @spec legacy_hash(String.t()) :: String.t()
  def legacy_hash(token) when is_binary(token) do
    :crypto.hash(:sha256, token)
    |> Base.encode16(case: :lower)
  end

  @doc """
  Performs constant-time comparison of two strings.

  This prevents timing attacks by ensuring the comparison takes
  the same amount of time regardless of where the strings differ.

  ## Examples

      iex> Plugboard.Crypto.secure_compare("abc", "abc")
      true
      iex> Plugboard.Crypto.secure_compare("abc", "abd")
      false
  """
  @spec secure_compare(String.t(), String.t()) :: boolean()
  def secure_compare(a, b) when is_binary(a) and is_binary(b) do
    Plug.Crypto.secure_compare(a, b)
  end

  def secure_compare(_, _), do: false

  @doc """
  Generates a secure random token.

  ## Parameters

    - `byte_length` - Number of random bytes (default: 32)

  ## Examples

      iex> token = Plugboard.Crypto.generate_token()
      iex> byte_size(token) > 40
      true
  """
  @spec generate_token(pos_integer()) :: String.t()
  def generate_token(byte_length \\ 32) do
    :crypto.strong_rand_bytes(byte_length)
    |> Base.url_encode64(padding: false)
  end

  # Private functions

  defp get_secret_key_base! do
    case Application.get_env(:plugboard, PlugboardWeb.Endpoint)[:secret_key_base] do
      nil ->
        raise "SECRET_KEY_BASE is not configured"

      secret when byte_size(secret) < 64 ->
        raise "SECRET_KEY_BASE must be at least 64 bytes"

      secret ->
        secret
    end
  end
end
