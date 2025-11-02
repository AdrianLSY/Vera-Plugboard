# Phase 3: WebSocket Telephone System - Implementation Plan

## Overview

Phase 3 introduces the WebSocket-based telephone system that allows backend servers to connect to Plugboard and serve HTTP traffic through persistent WebSocket connections. This eliminates the need for static reverse proxy configurations and enables dynamic service discovery.

---

## Key Design Decisions

### 1. Token-Path Relationship
- **Each token belongs to exactly ONE path** (1:1 relationship)
- Tokens stored in `telephone_tokens` table with `path_id` foreign key
- Simplifies security model: one telephone serves one mount point

### 2. Authentication Methods
- **Users with Owner/Maintainer role** can create tokens for their paths
- **API endpoint** for programmatic token generation
- JWT-based authentication with configurable expiry

### 3. Request Flow (Synchronous Model for MVP)
- **No correlation IDs** - one request at a time per telephone connection
- Simpler implementation and easier to reason about
- Use `Task.async` with timeout for concurrent handling across multiple telephones
- Phoenix Channel process manages WebSocket lifecycle

### 4. Timeout Configuration
- **Per-path timeout settings** stored in database
- `request_timeout_ms` - how long to wait for telephone response (default: 60s)
- `connect_timeout_ms` - connection establishment timeout (default: 5s)
- Allows different SLAs for different services

### 5. Load Balancing
- **Round-robin** distribution when multiple telephones on same path
- Tracked via `TelephoneRegistry` (ETS-backed GenServer)
- Simple counter increments for next telephone selection

### 6. Deferred to Later Phases
- ❌ Streaming (REQ_BODY, RES_BODY chunks) - Phase 4+
- ❌ Multi-node clustering - Phase 5
- ❌ Advanced load balancing (least-connections, latency-based) - Post-MVP

---

## Database Schema Changes

### New Table: `telephone_tokens`

```sql
CREATE TABLE telephone_tokens (
  id BINARY_ID PRIMARY KEY,
  path_id BINARY_ID NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
  user_id BINARY_ID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,           -- SHA256 hash of JWT for lookups
  description TEXT,                   -- User description ("Production server")
  expires_at TIMESTAMPTZ NOT NULL,
  revoked_at TIMESTAMPTZ NULL,
  last_used_at TIMESTAMPTZ NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE UNIQUE INDEX telephone_tokens_unique_hash
  ON telephone_tokens (token_hash)
  WHERE revoked_at IS NULL;

CREATE INDEX idx_telephone_tokens_path_id ON telephone_tokens (path_id);
CREATE INDEX idx_telephone_tokens_user_id ON telephone_tokens (user_id);
CREATE INDEX idx_telephone_tokens_expires_at ON telephone_tokens (expires_at);
```

**Key Points:**
- `token_hash` stores SHA256(JWT) for revocation checks
- `revoked_at IS NULL` means token is active
- `last_used_at` updated on each connection for audit trail

### Path Table Additions

```sql
ALTER TABLE paths
ADD COLUMN request_timeout_ms INTEGER DEFAULT 60000 NOT NULL,
ADD COLUMN connect_timeout_ms INTEGER DEFAULT 5000 NOT NULL;
```

---

## Configuration (Environment Variables)

Add to `.env` and load via `config/runtime.exs`:

```bash
# Telephone token configuration
TELEPHONE_TOKEN_EXPIRY=3600              # Token expiry in seconds (default: 1 hour)
TELEPHONE_TOKEN_REFRESH_INTERVAL=1800    # Refresh interval in seconds (default: 30 min)
```

Load in `runtime.exs`:

```elixir
config :plugboard, :telephone,
  token_expiry: System.get_env("TELEPHONE_TOKEN_EXPIRY", "3600") |> String.to_integer(),
  token_refresh_interval: System.get_env("TELEPHONE_TOKEN_REFRESH_INTERVAL", "1800") |> String.to_integer()
```

---

## JWT Structure

### Claims

```json
{
  "sub": "user_id",           // Subject: user who created token
  "jti": "token_id",          // JWT ID: telephone_tokens.id (for revocation)
  "path_id": "path_uuid",     // Path this telephone serves
  "iat": 1730000000,          // Issued at (Unix timestamp)
  "exp": 1730003600           // Expires at (iat + TELEPHONE_TOKEN_EXPIRY)
}
```

### Validation Steps

1. Decode JWT using `JOKEN` library
2. Verify signature with app secret key base
3. Check expiry (`exp` > current time)
4. Query `telephone_tokens` by `jti`:
   - Token exists
   - `revoked_at IS NULL`
   - `expires_at > now()`
5. Query `paths` by `path_id`:
   - Path exists
   - `mount_point = TRUE`
   - `deleted_at IS NULL`

---

## Architecture Components

### 1. TelephoneToken Context (`lib/plugboard/telephone_tokens/`)

**Schema** - `lib/plugboard/telephone_tokens/telephone_token.ex`:
```elixir
defmodule Plugboard.TelephoneTokens.TelephoneToken do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "telephone_tokens" do
    field :token_hash, :string
    field :description, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime
    field :last_used_at, :utc_datetime

    belongs_to :path, Plugboard.Paths.Path
    belongs_to :user, Plugboard.Accounts.User

    timestamps(type: :utc_datetime)
  end
end
```

**Context Functions** - `lib/plugboard/telephone_tokens.ex`:
```elixir
defmodule Plugboard.TelephoneTokens do
  # Generate new token for path
  def generate_token(path, user, description \\ nil)
  
  # Validate JWT and return token + path info
  def validate_jwt(jwt_string)
  
  # Revoke token
  def revoke_token(token_id)
  
  # Refresh token (generate new JWT, update expires_at)
  def refresh_token(token_id)
  
  # Update last_used_at timestamp
  def mark_token_used(token_id)
  
  # List tokens for path
  def list_tokens_for_path(path_id)
  
  # Clean up expired tokens (background job)
  def delete_expired_tokens()
end
```

### 2. TelephoneSocket (`lib/plugboard_web/channels/telephone_socket.ex`)

```elixir
defmodule PlugboardWeb.TelephoneSocket do
  use Phoenix.Socket

  channel "telephone:*", PlugboardWeb.TelephoneChannel

  @impl true
  def connect(%{"token" => jwt}, socket, _connect_info) do
    case Plugboard.TelephoneTokens.validate_jwt(jwt) do
      {:ok, %{token_id: token_id, path_id: path_id, path: path}} ->
        socket = 
          socket
          |> assign(:token_id, token_id)
          |> assign(:path_id, path_id)
          |> assign(:path, path)
        
        {:ok, socket}
      
      {:error, reason} ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "telephone:#{socket.assigns.path_id}"
end
```

### 3. TelephoneChannel (`lib/plugboard_web/channels/telephone_channel.ex`)

```elixir
defmodule PlugboardWeb.TelephoneChannel do
  use PlugboardWeb, :channel
  
  alias Plugboard.TelephoneRegistry
  alias Plugboard.TelephoneTokens

  @impl true
  def join("telephone:" <> path_id, _payload, socket) do
    if socket.assigns.path_id == path_id do
      # Register telephone in registry
      :ok = TelephoneRegistry.register(path_id, self())
      
      # Update last_used_at
      TelephoneTokens.mark_token_used(socket.assigns.token_id)
      
      # Send acknowledgment
      {:ok, %{status: "ok", path: socket.assigns.path.full_path}, socket}
    else
      {:error, %{reason: "path_id mismatch"}}
    end
  end

  @impl true
  def handle_in("heartbeat", %{"ts" => ts}, socket) do
    push(socket, "heartbeat_ack", %{ts: ts})
    {:noreply, socket}
  end

  @impl true
  def handle_in("refresh_token", _payload, socket) do
    case TelephoneTokens.refresh_token(socket.assigns.token_id) do
      {:ok, new_jwt, expires_in} ->
        push(socket, "refresh_token_ack", %{token: new_jwt, expires_in: expires_in})
        {:noreply, socket}
      
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  @impl true
  def handle_in("proxy_res", payload, socket) do
    # Response handled by ProxyController via Task
    # This message is received but response already sent
    {:noreply, socket}
  end

  @impl true
  def terminate(reason, socket) do
    TelephoneRegistry.unregister(socket.assigns.path_id, self())
    :ok
  end
end
```

### 4. TelephoneRegistry (`lib/plugboard/telephone_registry.ex`)

```elixir
defmodule Plugboard.TelephoneRegistry do
  use GenServer
  
  # ETS table structure:
  # {:telephones, path_id, [telephone_pid, ...]}
  # {:counters, path_id, counter}

  # Public API
  def start_link(opts)
  def register(path_id, telephone_pid)
  def unregister(path_id, telephone_pid)
  def get_telephone(path_id)  # Returns next telephone (round-robin)
  def list_telephones(path_id)
  def count_telephones(path_id)

  # GenServer callbacks
  @impl true
  def init(_opts) do
    table = :ets.new(:telephone_registry, [:set, :public, :named_table])
    {:ok, %{table: table}}
  end

  # Round-robin implementation
  def handle_call({:get_telephone, path_id}, _from, state) do
    case :ets.lookup(:telephone_registry, {:telephones, path_id}) do
      [{_, telephones}] when telephones != [] ->
        # Get current counter
        counter = get_counter(path_id)
        
        # Select telephone
        index = rem(counter, length(telephones))
        telephone_pid = Enum.at(telephones, index)
        
        # Increment counter
        :ets.update_counter(:telephone_registry, {:counters, path_id}, {2, 1}, {{:counters, path_id}, 0})
        
        {:reply, {:ok, telephone_pid}, state}
      
      _ ->
        {:reply, {:error, :no_telephone}, state}
    end
  end
end
```

### 5. Updated ProxyController (`lib/plugboard_web/controllers/proxy_controller.ex`)

```elixir
defmodule PlugboardWeb.ProxyController do
  use PlugboardWeb, :controller
  
  alias Plugboard.MountStore
  alias Plugboard.TelephoneRegistry
  alias Plugboard.Paths

  def proxy(conn, %{"path" => request_path}) do
    case MountStore.match(request_path) do
      {:ok, {mount_path, forwarded_path, mount_id}} ->
        proxy_to_telephone(conn, mount_id, forwarded_path)
      
      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No mount point found"})
    end
  end

  defp proxy_to_telephone(conn, path_id, forwarded_path) do
    # Get path for timeout config
    path = Paths.get_path!(path_id)
    timeout = path.request_timeout_ms
    
    # Get telephone via round-robin
    case TelephoneRegistry.get_telephone(path_id) do
      {:ok, telephone_pid} ->
        # Forward request to telephone
        task = Task.async(fn ->
          send_proxy_request(telephone_pid, conn, forwarded_path)
        end)
        
        case Task.await(task, timeout) do
          {:ok, response} ->
            send_response(conn, response)
          
          {:error, :timeout} ->
            conn
            |> put_status(:gateway_timeout)
            |> json(%{error: "Telephone response timeout"})
        end
      
      {:error, :no_telephone} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "No telephone available for this path"})
    end
  end

  defp send_proxy_request(telephone_pid, conn, forwarded_path) do
    # Build request payload
    request = %{
      method: conn.method,
      path: forwarded_path,
      headers: build_headers(conn),
      body: read_body(conn)
    }
    
    # Push to telephone and wait for response
    ref = make_ref()
    Phoenix.Channel.push(telephone_pid, "proxy_req", request)
    
    receive do
      {:proxy_res, ^ref, response} -> {:ok, response}
    after
      60_000 -> {:error, :timeout}
    end
  end
end
```

---

## API Endpoint for Token Creation

### Route
```elixir
# lib/plugboard_web/router.ex
scope "/api", PlugboardWeb.Api do
  pipe_through [:api, :require_authenticated_user]
  
  post "/paths/:path_id/tokens", TelephoneTokenController, :create
  get "/paths/:path_id/tokens", TelephoneTokenController, :index
  delete "/tokens/:id", TelephoneTokenController, :delete
end
```

### Controller
```elixir
defmodule PlugboardWeb.Api.TelephoneTokenController do
  use PlugboardWeb, :controller
  
  alias Plugboard.TelephoneTokens
  alias Plugboard.Paths
  
  def create(conn, %{"path_id" => path_id, "description" => description}) do
    user = conn.assigns.current_scope.user
    path = Paths.get_path!(path_id)
    
    # Check user has owner or maintainer role
    case Paths.get_user_role(user.id, path_id) do
      role when role in ["owner", "maintainer"] ->
        case TelephoneTokens.generate_token(path, user, description) do
          {:ok, jwt, token} ->
            json(conn, %{
              token: jwt,
              id: token.id,
              expires_at: token.expires_at,
              description: token.description
            })
          
          {:error, reason} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: reason})
        end
      
      _ ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Requires owner or maintainer role"})
    end
  end
end
```

---

## Telemetry Events

Emit telemetry for monitoring:

```elixir
# Telephone connection
:telemetry.execute(
  [:plugboard, :telephone, :connected],
  %{count: 1},
  %{path_id: path_id}
)

# Telephone disconnection
:telemetry.execute(
  [:plugboard, :telephone, :disconnected],
  %{count: 1, duration: duration_ms},
  %{path_id: path_id, reason: reason}
)

# Proxy request
:telemetry.execute(
  [:plugboard, :telephone, :proxy_request],
  %{duration: duration_ms},
  %{path_id: path_id, method: method, status: status}
)

# Proxy timeout
:telemetry.execute(
  [:plugboard, :telephone, :proxy_timeout],
  %{count: 1},
  %{path_id: path_id, timeout_ms: timeout}
)
```

---

## Testing Strategy

### Unit Tests

1. **TelephoneToken Context**
   - `generate_token/3` creates valid JWT
   - `validate_jwt/1` accepts valid tokens
   - `validate_jwt/1` rejects expired tokens
   - `validate_jwt/1` rejects revoked tokens
   - `revoke_token/1` sets revoked_at
   - `refresh_token/1` generates new JWT with updated expiry

2. **TelephoneRegistry**
   - `register/2` adds telephone to path
   - `unregister/2` removes telephone from path
   - `get_telephone/1` returns telephones in round-robin order
   - Multiple telephones on same path balanced correctly

### Integration Tests

1. **WebSocket Connection**
   - Telephone connects with valid JWT → success
   - Telephone connects with invalid JWT → rejected
   - Telephone connects with expired JWT → rejected
   - Telephone connects with revoked token → rejected

2. **Request Proxying**
   - HTTP request → matched to path → forwarded to telephone → response returned
   - Request to path with no telephone → 503 Service Unavailable
   - Request timeout → 504 Gateway Timeout
   - Multiple requests distributed round-robin across telephones

3. **Token Management**
   - Owner can create token for path → success
   - Maintainer can create token for path → success
   - Viewer cannot create token → 403 Forbidden
   - Token refresh updates expiry and returns new JWT

---

## Migration Timeline

### Step 1: Database Migrations
- Create `telephone_tokens` table
- Add timeout columns to `paths` table

### Step 2: Schema & Context
- Implement `TelephoneToken` schema
- Implement `TelephoneTokens` context with JWT functions

### Step 3: WebSocket Infrastructure
- Implement `TelephoneSocket`
- Implement `TelephoneChannel`
- Implement `TelephoneRegistry`

### Step 4: Proxy Integration
- Update `ProxyController` to forward requests
- Add timeout handling with Task.async

### Step 5: API & UI
- Create token management API endpoints
- Add telemetry events

### Step 6: Testing
- Unit tests for all components
- Integration tests for end-to-end flow

---

## Success Criteria

Phase 3 is complete when:

- ✅ Telephone can connect with valid JWT token
- ✅ Invalid/expired/revoked tokens are rejected
- ✅ HTTP requests are proxied to connected telephones
- ✅ Responses are returned to HTTP clients
- ✅ Multiple telephones receive requests in round-robin order
- ✅ Timeouts return correct HTTP status codes (504, 503)
- ✅ Token creation API enforces owner/maintainer roles
- ✅ Token refresh mechanism works over WebSocket
- ✅ All tests passing
- ✅ Telemetry events emitted for monitoring

---

## Next Steps (Phase 4)

After Phase 3 is complete:
- Implement streaming support (REQ_BODY, RES_BODY chunks)
- Enhanced error handling and partial response management
- Better timeout configuration and retry logic
