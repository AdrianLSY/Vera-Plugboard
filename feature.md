# Hooks Feature Specification

## Overview

Hooks are a middleware system that allows requests to be processed by intermediary services before reaching the target backend. Hooks execute sequentially, with each hook receiving the accumulated request body (including responses from previous hooks). This enables use cases like authentication, authorization, rate limiting, request enrichment, and more.

### Key Concepts

- **Pre-Hooks**: Execute sequentially before the request reaches the target backend. Each hook can inspect and augment the request body.
- **Sequential Execution**: Hooks execute in order (1, 2, 3...) with each hook receiving the merged body from all previous hooks.
- **Body Merging**: Hook responses are merged at the root level into the request body that flows through the chain.
- **Status Code Whitelisting**: Each hook defines allowed status codes. Non-whitelisted codes stop execution and return the hook's response to the client.
- **Mount Point Level**: Hooks are configured per mount point and apply to all requests to that path (both `/call/*` and domain affinity routes).
- **Dual Target Support**: Hooks can call internal Plugboard mount points (via WebSocket/telephone) OR external HTTP endpoints.

## Use Cases

1. **Authentication**: Verify JWT tokens and inject user context into request body
2. **Authorization**: Check user permissions and add role/scope information
3. **Request Enrichment**: Add tenant metadata, feature flags, or user preferences
4. **Rate Limiting**: Validate rate limits and inject quota information
5. **Data Validation**: Validate request against business rules and inject validation metadata
6. **Multi-Factor Auth**: Chain multiple auth checks (JWT → IP whitelist → device fingerprint)
7. **A/B Testing**: Inject experiment variant information based on user ID

## Request Flow Example

### Original Request
```http
POST /call/users/create HTTP/1.1
Content-Type: application/json

{
  "name": "John Doe",
  "email": "john@example.com"
}
```

### Hook Chain Configuration
1. **Auth Hook** → `/call/auth/verify` (order: 1)
2. **Rate Limit Hook** → `https://ratelimit.external.com/check` (order: 2)
3. **Enrichment Hook** → `/call/tenant/enrich` (order: 3)

### Execution Flow

#### Step 1: Auth Hook
**Request to `/call/auth/verify`**:
```json
{
  "name": "John Doe",
  "email": "john@example.com"
}
```

**Auth Response** (200 OK):
```json
{
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true
}
```

**Merged Body** (sent to next hook):
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true
}
```

#### Step 2: Rate Limit Hook
**Request to `https://ratelimit.external.com/check`**:
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true
}
```

**Rate Limit Response** (200 OK):
```json
{
  "rate_limit_remaining": 95,
  "rate_limit_reset": 1705334400
}
```

**Merged Body**:
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true,
  "rate_limit_remaining": 95,
  "rate_limit_reset": 1705334400
}
```

#### Step 3: Enrichment Hook
**Request to `/call/tenant/enrich`**:
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true,
  "rate_limit_remaining": 95,
  "rate_limit_reset": 1705334400
}
```

**Enrichment Response** (200 OK):
```json
{
  "tenant_id": "org_456",
  "tenant_name": "Acme Corp",
  "features": ["advanced_analytics", "api_access"]
}
```

**Final Merged Body** (sent to target backend `/call/users/create`):
```json
{
  "name": "John Doe",
  "email": "john@example.com",
  "user_id": "usr_123",
  "roles": ["admin", "editor"],
  "verified": true,
  "rate_limit_remaining": 95,
  "rate_limit_reset": 1705334400,
  "tenant_id": "org_456",
  "tenant_name": "Acme Corp",
  "features": ["advanced_analytics", "api_access"]
}
```

### Failure Scenario

If **Rate Limit Hook** returns 429 (not in whitelist):

**Rate Limit Response** (429 Too Many Requests):
```json
{
  "error": "Rate limit exceeded",
  "retry_after": 3600
}
```

**Client receives** (execution stops, backend never called):
```http
HTTP/1.1 429 Too Many Requests
Content-Type: application/json

{
  "error": "Rate limit exceeded",
  "retry_after": 3600
}
```

## Technical Specification

### 1. Database Schema

#### Hooks Table

```sql
CREATE TABLE hooks (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  
  -- Association
  path_id UUID NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
  
  -- Hook Configuration
  name VARCHAR(255) NOT NULL,
  description TEXT,
  
  -- Target Configuration (supports both internal mount points and external HTTP)
  target_type VARCHAR(20) NOT NULL DEFAULT 'mount_point' CHECK (target_type IN ('mount_point', 'http_url')),
  target_path_id UUID REFERENCES paths(id) ON DELETE RESTRICT,  -- Used when target_type = 'mount_point'
  target_url TEXT,  -- Used when target_type = 'http_url' (e.g., https://auth.example.com/verify)
  
  -- Execution Configuration
  execution_order INTEGER NOT NULL DEFAULT 0,
  timeout_ms INTEGER NOT NULL DEFAULT 5000 CHECK (timeout_ms > 0 AND timeout_ms <= 60000),
  
  -- Status Code Whitelisting
  allowed_status_codes JSONB NOT NULL DEFAULT '[200, 201, 202, 204]'::jsonb,
  
  -- Request Configuration
  forward_headers JSONB DEFAULT '[]'::jsonb,  -- Array of header names to forward to hook (in addition to body)
  forward_query_params BOOLEAN DEFAULT false,  -- Whether to include query parameters in hook request
  
  -- Soft Delete
  deleted_at TIMESTAMPTZ,
  
  -- Timestamps
  inserted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Indexes
CREATE INDEX idx_hooks_path_id ON hooks(path_id) WHERE deleted_at IS NULL;
CREATE INDEX idx_hooks_execution_order ON hooks(path_id, execution_order) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX idx_hooks_unique_order ON hooks(path_id, execution_order) WHERE deleted_at IS NULL;

-- Constraint: target_path_id required if target_type = 'mount_point'
ALTER TABLE hooks ADD CONSTRAINT check_target_config 
  CHECK (
    (target_type = 'mount_point' AND target_path_id IS NOT NULL AND target_url IS NULL) OR
    (target_type = 'http_url' AND target_url IS NOT NULL AND target_path_id IS NULL)
  );

-- Trigger for PostgreSQL NOTIFY on hook changes
CREATE OR REPLACE FUNCTION notify_hook_change()
RETURNS TRIGGER AS $$
BEGIN
  IF TG_OP = 'INSERT' OR TG_OP = 'UPDATE' THEN
    PERFORM pg_notify('plugboard_hooks', 
      json_build_object(
        'action', 'hook_updated',
        'path_id', NEW.path_id,
        'hook_id', NEW.id
      )::text
    );
  ELSIF TG_OP = 'DELETE' THEN
    PERFORM pg_notify('plugboard_hooks',
      json_build_object(
        'action', 'hook_deleted',
        'path_id', OLD.path_id,
        'hook_id', OLD.id
      )::text
    );
  END IF;
  RETURN NULL;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trigger_notify_hook_change
AFTER INSERT OR UPDATE OR DELETE ON hooks
FOR EACH ROW EXECUTE FUNCTION notify_hook_change();
```

### 2. Hook Execution Flow

```
Client Request (POST /call/users/create)
    ↓
[ValidatePath Plug]
    ↓
[ProxyController.proxy]
    ↓
[MountStore.match] → Find mount point for /users
    ↓
[HookStore.get_hooks(path_id)] → Load hooks ordered by execution_order
    ↓
┌─────────────────────────────────────────────────────┐
│  Execute Hooks Sequentially                         │
│                                                     │
│  accumulated_body = original_request_body           │
│                                                     │
│  For each hook (1, 2, 3...):                       │
│    1. Build hook request with accumulated_body      │
│    2. Call hook target:                            │
│       - If target_type = 'mount_point':            │
│           → Use telephone (internal proxy)         │
│       - If target_type = 'http_url':               │
│           → Make HTTP request                      │
│    3. Check response status code                   │
│    4. If status in allowed_status_codes:           │
│         - Parse hook response body (JSON)          │
│         - Merge response into accumulated_body     │
│           (root level merge, hook response wins    │
│            on key conflicts)                       │
│         - Continue to next hook                    │
│    5. If status NOT in allowed_status_codes:       │
│         - Return hook's response to client         │
│         - STOP (don't call backend or next hooks)  │
│    6. If timeout or connection error:              │
│         - Return 504/503 error to client           │
│         - STOP                                     │
└─────────────────────────────────────────────────────┘
    ↓ (All hooks passed)
[Get Telephone from Registry for target backend]
    ↓
[Forward request with accumulated_body to backend]
    ↓
[Receive backend response]
    ↓
[Return response to client]
```

### 3. Hook Request Format

#### For Mount Point Targets (via Telephone)

Same format as regular proxy requests, sent via Elixir message passing:

```elixir
%{
  "request_id" => "hook-req-uuid",
  "method" => "POST",  # Always POST for hooks (sending body)
  "path" => "/verify",  # Path within the mount point
  "headers" => %{
    "content-type" => "application/json",
    "x-original-method" => "POST",
    "x-original-path" => "/users/create",
    "x-hook-id" => "hook-uuid",
    "x-hook-name" => "auth-verification",
    # Additional headers from forward_headers config
    "authorization" => "Bearer ...",
  },
  "body" => Jason.encode!(accumulated_body),
  "query_string" => ""  # Or original query if forward_query_params = true
}
```

#### For HTTP URL Targets (External)

Standard HTTP POST request:

```http
POST https://auth.external.com/verify HTTP/1.1
Content-Type: application/json
X-Original-Method: POST
X-Original-Path: /users/create
X-Hook-ID: hook-uuid
X-Hook-Name: auth-verification
Authorization: Bearer ...

{
  "name": "John Doe",
  "email": "john@example.com"
}
```

### 4. Hook Response Handling

#### Success Response (Status in Whitelist)

Hook returns status code in `allowed_status_codes`:

```http
HTTP/1.1 200 OK
Content-Type: application/json

{
  "user_id": "usr_123",
  "roles": ["admin"],
  "verified": true
}
```

**Processing**:
1. Parse JSON response body
2. Merge at root level into accumulated_body:
   ```elixir
   accumulated_body = Map.merge(accumulated_body, hook_response_body)
   ```
3. Continue to next hook (or backend if last hook)

**Key Conflict Behavior**:
If accumulated_body has `{"user_id": "old"}` and hook returns `{"user_id": "new"}`:
- Result: `{"user_id": "new"}` (hook response wins)
- This allows hooks to override/transform previous values

#### Failure Response (Status NOT in Whitelist)

Hook returns non-whitelisted status (e.g., 401, 403, 429):

```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{
  "error": "Invalid token",
  "code": "AUTH_FAILED"
}
```

**Processing**:
1. Stop hook chain execution
2. Return hook's response to client as-is (status, headers, body)
3. Backend is never called
4. Log hook failure with telemetry

**Client receives exactly**:
```http
HTTP/1.1 401 Unauthorized
Content-Type: application/json

{
  "error": "Invalid token",
  "code": "AUTH_FAILED"
}
```

#### Timeout Response

Hook doesn't respond within `timeout_ms`:

**Processing**:
1. Stop hook chain execution
2. Return 504 Gateway Timeout to client

```http
HTTP/1.1 504 Gateway Timeout
Content-Type: application/json

{
  "error": "Hook timeout",
  "hook_name": "auth-verification",
  "timeout_ms": 5000
}
```

#### Connection Error (Hook Unavailable)

Hook backend is unreachable or returns connection error:

**Processing**:
1. Stop hook chain execution
2. Return 503 Service Unavailable to client

```http
HTTP/1.1 503 Service Unavailable
Content-Type: application/json

{
  "error": "Hook unavailable",
  "hook_name": "auth-verification"
}
```

### 5. Body Merging Behavior

#### Simple Merge
```elixir
# Accumulated body
%{"name" => "John", "email" => "john@example.com"}

# Hook response
%{"user_id" => "123", "verified" => true}

# Merged result
%{
  "name" => "John",
  "email" => "john@example.com",
  "user_id" => "123",
  "verified" => true
}
```

#### Nested Objects (Shallow Merge)
```elixir
# Accumulated body
%{"user" => %{"name" => "John"}, "action" => "create"}

# Hook response
%{"user" => %{"id" => "123"}}

# Merged result (user object replaced entirely)
%{
  "user" => %{"id" => "123"},  # Original user.name lost!
  "action" => "create"
}
```

**Note**: Merge is **shallow** at the root level. Nested objects are replaced entirely, not deep-merged. Hooks should be aware of this behavior.

#### Array Handling
```elixir
# Accumulated body
%{"tags" => ["urgent"]}

# Hook response
%{"tags" => ["verified", "admin"]}

# Merged result
%{"tags" => ["verified", "admin"]}  # Array replaced, not concatenated
```

### 6. Hook Store (In-Memory Cache)

```elixir
defmodule Plugboard.HookStore do
  @moduledoc """
  ETS-based cache for hooks with PostgreSQL synchronization.
  
  Provides O(1) lookup of hooks by path_id.
  Listens to PostgreSQL NOTIFY for real-time updates.
  """
  
  use GenServer
  
  @table_name :plugboard_hooks
  
  # Client API
  
  def start_link(opts)
  
  @doc """
  Returns hooks for a path, ordered by execution_order.
  """
  def get_hooks(path_id) do
    case :ets.lookup(@table_name, path_id) do
      [{^path_id, hooks}] -> hooks
      [] -> []
    end
  end
  
  def refresh_hooks(path_id)
  def reload_all()
  
  # Server implementation similar to MountStore
  # - Load hooks from database on startup
  # - Listen to 'plugboard_hooks' NOTIFY channel
  # - Periodic reconciliation
end
```

### 7. Hook Execution Implementation

```elixir
defmodule Plugboard.Hooks.Executor do
  @moduledoc """
  Executes hooks sequentially and merges responses into request body.
  """
  
  require Logger
  alias Plugboard.HookStore
  alias Plugboard.TelephoneRegistry
  alias Plugboard.MountStore
  
  @doc """
  Executes all hooks for a path and returns the modified connection.
  
  Returns:
    - {:ok, conn_with_modified_body} on success
    - {:error, :hook_rejected, hook, response} on hook failure
    - {:error, :timeout, hook} on timeout
    - {:error, :unavailable, hook} on connection error
  """
  def execute_hooks(conn, path_id) do
    hooks = HookStore.get_hooks(path_id)
    
    if Enum.empty?(hooks) do
      {:ok, conn}
    else
      # Read original request body
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      
      # Parse JSON (or use empty map if body is empty)
      initial_body = parse_body(body)
      
      # Execute hooks sequentially
      case execute_hook_chain(conn, hooks, initial_body) do
        {:ok, final_body} ->
          # Replace conn body with merged result
          modified_conn = put_modified_body(conn, final_body)
          {:ok, modified_conn}
        
        error -> error
      end
    end
  end
  
  defp execute_hook_chain(conn, hooks, accumulated_body) do
    Enum.reduce_while(hooks, {:ok, accumulated_body}, fn hook, {:ok, body} ->
      case execute_single_hook(conn, hook, body) do
        {:ok, hook_response_body} ->
          # Merge hook response into accumulated body (root level merge)
          merged_body = Map.merge(body, hook_response_body)
          
          Logger.debug(
            "Hook #{hook.name} succeeded, merged #{map_size(hook_response_body)} keys"
          )
          
          {:cont, {:ok, merged_body}}
        
        {:error, reason, response} ->
          {:halt, {:error, reason, hook, response}}
      end
    end)
  end
  
  defp execute_single_hook(conn, hook, body) do
    start_time = System.monotonic_time()
    
    case hook.target_type do
      "mount_point" ->
        execute_mount_point_hook(conn, hook, body)
      
      "http_url" ->
        execute_http_hook(conn, hook, body)
    end
    |> handle_hook_response(hook, start_time)
  end
  
  defp execute_mount_point_hook(conn, hook, body) do
    # Get target path details
    target_path = Repo.get!(Path, hook.target_path_id)
    
    # Match against mount store to get telephone
    case MountStore.match(target_path.full_path) do
      {:ok, {_mount_path, forwarded_path, mount_id}} ->
        case TelephoneRegistry.get_telephone(mount_id) do
          {:ok, telephone_pid} ->
            # Build request payload
            payload = build_hook_payload(conn, hook, body, forwarded_path)
            
            # Send to telephone and wait for response
            send_to_telephone_and_wait(
              telephone_pid,
              payload,
              hook.timeout_ms
            )
          
          {:error, :no_telephone} ->
            {:error, :unavailable}
        end
      
      {:error, :not_found} ->
        {:error, :unavailable}
    end
  end
  
  defp execute_http_hook(conn, hook, body) do
    # Build HTTP request
    headers = build_http_headers(conn, hook)
    json_body = Jason.encode!(body)
    
    # Make HTTP POST request
    case HTTPoison.post(
      hook.target_url,
      json_body,
      headers,
      timeout: hook.timeout_ms,
      recv_timeout: hook.timeout_ms
    ) do
      {:ok, %HTTPoison.Response{status_code: status, body: response_body}} ->
        {:ok, status, response_body}
      
      {:error, %HTTPoison.Error{reason: :timeout}} ->
        {:error, :timeout}
      
      {:error, _reason} ->
        {:error, :unavailable}
    end
  end
  
  defp handle_hook_response({:ok, status, response_body}, hook, start_time) do
    duration = System.monotonic_time() - start_time
    
    # Emit telemetry
    :telemetry.execute(
      [:plugboard, :hook, :executed],
      %{duration: duration},
      %{
        hook_id: hook.id,
        hook_name: hook.name,
        status: status,
        allowed: status in hook.allowed_status_codes
      }
    )
    
    if status in hook.allowed_status_codes do
      # Success - parse and return response body
      case Jason.decode(response_body) do
        {:ok, parsed_body} when is_map(parsed_body) ->
          {:ok, parsed_body}
        
        {:ok, _non_map} ->
          Logger.warning("Hook #{hook.name} returned non-object JSON, ignoring")
          {:ok, %{}}
        
        {:error, _} ->
          Logger.warning("Hook #{hook.name} returned invalid JSON, ignoring")
          {:ok, %{}}
      end
    else
      # Hook rejected - return error with hook's response
      {:error, :rejected, %{status: status, body: response_body}}
    end
  end
  
  defp handle_hook_response({:error, :timeout}, _hook, start_time) do
    duration = System.monotonic_time() - start_time
    
    :telemetry.execute(
      [:plugboard, :hook, :timeout],
      %{duration: duration},
      %{hook_id: hook.id, hook_name: hook.name}
    )
    
    {:error, :timeout, nil}
  end
  
  defp handle_hook_response({:error, :unavailable}, _hook, _start_time) do
    :telemetry.execute(
      [:plugboard, :hook, :unavailable],
      %{count: 1},
      %{hook_id: hook.id, hook_name: hook.name}
    )
    
    {:error, :unavailable, nil}
  end
  
  defp build_hook_payload(conn, hook, body, forwarded_path) do
    headers = build_hook_headers(conn, hook)
    
    %{
      "request_id" => Ecto.UUID.generate(),
      "method" => "POST",
      "path" => forwarded_path,
      "headers" => headers,
      "body" => Jason.encode!(body),
      "query_string" => if(hook.forward_query_params, do: conn.query_string, else: "")
    }
  end
  
  defp build_hook_headers(conn, hook) do
    base_headers = %{
      "content-type" => "application/json",
      "x-original-method" => conn.method,
      "x-original-path" => conn.request_path,
      "x-hook-id" => hook.id,
      "x-hook-name" => hook.name
    }
    
    # Add headers from forward_headers config
    forwarded = hook.forward_headers
    |> Enum.reduce(%{}, fn header_name, acc ->
      case Plug.Conn.get_req_header(conn, String.downcase(header_name)) do
        [value | _] -> Map.put(acc, String.downcase(header_name), value)
        [] -> acc
      end
    end)
    
    Map.merge(base_headers, forwarded)
  end
  
  defp build_http_headers(conn, hook) do
    hook_headers = build_hook_headers(conn, hook)
    
    # Convert to HTTPoison header format (list of tuples)
    Enum.map(hook_headers, fn {k, v} -> {k, v} end)
  end
  
  defp parse_body(""), do: %{}
  defp parse_body(body) do
    case Jason.decode(body) do
      {:ok, parsed} when is_map(parsed) -> parsed
      _ -> %{}
    end
  end
  
  defp put_modified_body(conn, body) do
    json_body = Jason.encode!(body)
    
    conn
    |> Map.put(:body_params, body)
    |> Plug.Conn.put_private(:raw_body, json_body)
  end
  
  defp send_to_telephone_and_wait(telephone_pid, payload, timeout) do
    request_id = payload["request_id"]
    
    if Process.alive?(telephone_pid) do
      send(telephone_pid, {:proxy_request, self(), request_id, payload})
      
      receive do
        {:proxy_res, ^request_id, response} ->
          {:ok, response["status"], response["body"]}
        
        {:proxy_error, ^request_id, _reason} ->
          {:error, :unavailable}
      after
        timeout ->
          {:error, :timeout}
      end
    else
      {:error, :unavailable}
    end
  end
end
```

### 8. Integration with ProxyController

```elixir
# lib/plugboard_web/controllers/proxy_controller.ex

def proxy(conn, params) do
  request_path = build_request_path(params)
  
  case MountStore.match(request_path) do
    {:ok, {mount_path, forwarded_path, mount_id}} ->
      # Execute hooks before forwarding to backend
      case Hooks.Executor.execute_hooks(conn, mount_id) do
        {:ok, modified_conn} ->
          # Hooks passed - proceed with proxy
          proxy_to_telephone(modified_conn, mount_id, forwarded_path)
        
        {:error, :hook_rejected, hook, response} ->
          # Hook rejected request - return hook's response
          send_hook_error_response(conn, hook, response)
        
        {:error, :timeout, hook} ->
          HTTPError.send_error(conn, 504,
            reason: "Hook timeout",
            details: %{hook_name: hook.name, timeout_ms: hook.timeout_ms}
          )
        
        {:error, :unavailable, hook} ->
          HTTPError.send_error(conn, 503,
            reason: "Hook unavailable",
            details: %{hook_name: hook.name}
          )
      end
    
    {:error, :not_found} ->
      HTTPError.send_error(conn, 404,
        reason: "No mount point found",
        details: %{path: request_path}
      )
  end
end

defp send_hook_error_response(conn, hook, %{status: status, body: body}) do
  Logger.info("Request rejected by hook #{hook.name} with status #{status}")
  
  conn
  |> put_status(status)
  |> put_resp_content_type("application/json")
  |> send_resp(status, body)
end
```

### 9. API Endpoints

```
POST   /api/paths/:path_id/hooks              Create hook
GET    /api/paths/:path_id/hooks              List hooks for path
GET    /api/hooks/:id                         Get hook details
PUT    /api/hooks/:id                         Update hook
DELETE /api/hooks/:id                         Delete hook (soft delete)
PATCH  /api/paths/:path_id/hooks/reorder      Reorder hooks

POST   /api/hooks/:id/test                    Test hook execution
```

#### Create Hook Examples

**Mount Point Hook**:
```bash
POST /api/paths/abc-123/hooks
Content-Type: application/json
Authorization: Bearer user-token

{
  "name": "Auth Verification",
  "description": "Verify JWT tokens with internal auth service",
  "target_type": "mount_point",
  "target_path_id": "auth-service-mount-id",
  "execution_order": 1,
  "timeout_ms": 5000,
  "allowed_status_codes": [200, 204],
  "forward_headers": ["authorization", "x-api-key"],
  "forward_query_params": false
}
```

**HTTP URL Hook**:
```bash
POST /api/paths/abc-123/hooks
Content-Type: application/json
Authorization: Bearer user-token

{
  "name": "External Rate Limiter",
  "description": "Check rate limits with external service",
  "target_type": "http_url",
  "target_url": "https://ratelimit.external.com/check",
  "execution_order": 2,
  "timeout_ms": 3000,
  "allowed_status_codes": [200],
  "forward_headers": ["x-client-ip"],
  "forward_query_params": false
}
```

### 10. Telemetry Events

```elixir
# Hook execution success
[:plugboard, :hook, :executed]
%{duration: native_time}
%{hook_id: "...", hook_name: "...", status: 200, allowed: true}

# Hook execution failure (non-whitelisted status)
[:plugboard, :hook, :executed]
%{duration: native_time}
%{hook_id: "...", hook_name: "...", status: 401, allowed: false}

# Hook timeout
[:plugboard, :hook, :timeout]
%{duration: native_time}
%{hook_id: "...", hook_name: "..."}

# Hook unavailable
[:plugboard, :hook, :unavailable]
%{count: 1}
%{hook_id: "...", hook_name: "..."}

# Complete hook chain executed
[:plugboard, :hook, :chain_completed]
%{duration: native_time, hook_count: 3}
%{path_id: "...", success: true}
```

### 11. UI/UX Design

#### Hooks Management Page

**Location**: `/paths/:path_id/hooks` (accessible from Paths list)

**Features**:

1. **Hooks List**:
   - Sequential order display (1 → 2 → 3 → Backend)
   - Visual flow diagram
   - Drag-and-drop to reorder
   - Status indicators (active/inactive)
   - Recent execution stats (success rate, avg latency, rejection rate)

2. **Create/Edit Hook Form**:
   - Hook name and description
   - Target type selector (radio): Mount Point / HTTP URL
   - If mount point: Dropdown of available mount points
   - If HTTP URL: Text input for URL
   - Execution order: Auto-assigned (next available) with manual override
   - Timeout: Slider (1-60 seconds, default 5s)
   - Allowed status codes: Chips input (default: 200, 201, 202, 204)
   - Advanced settings (collapsible):
     - Forward headers: Multi-select checkboxes
     - Forward query params: Toggle
   
3. **Test Hook**:
   - Sample request body input (JSON editor)
   - Execute test button
   - Shows:
     - Request sent to hook
     - Response received from hook
     - Merged body result
     - Execution time
     - Success/failure indication

4. **Hook Execution Logs**:
   - Recent executions (last 100)
   - Filter by hook, success/failure, date range
   - Shows: timestamp, status code, duration, request/response preview
   - Click to expand full request/response details

#### Example UI Flow

```
Paths List
  → Click "Users API" (/call/users)
    → Tabs: [Overview] [Tokens] [Hooks] [Domain Affinities]
      → Click [Hooks]
      
        Request Flow Diagram:
        ┌─────────┐    ┌──────────┐    ┌─────────┐    ┌─────────┐
        │ Client  │ → │ 1. Auth  │ → │ 2. Rate │ → │ Backend │
        │ Request │    │ Verify   │    │ Limit   │    │ /users  │
        └─────────┘    └──────────┘    └─────────┘    └─────────┘
                       200: ✓ 99.8%    200: ✓ 98.1%
                       Avg: 45ms        Avg: 12ms
        
        Hooks:
        
        [1] Auth Verification
            Target: /call/auth (mount point)
            Timeout: 5s | Allowed: 200, 204
            ✓ Success: 99.8% | ✗ Rejected: 0.2% | Avg: 45ms
            [Edit] [Test] [Delete] [↑] [↓]
        
        [2] Rate Limiter  
            Target: https://ratelimit.example.com/check (HTTP)
            Timeout: 3s | Allowed: 200
            ✓ Success: 98.1% | ✗ Rejected: 1.9% | Avg: 12ms
            [Edit] [Test] [Delete] [↑] [↓]
        
        [+ Add Hook]
        
        Recent Activity (last 24h):
        - Total requests: 12,450
        - Passed all hooks: 12,203 (98.0%)
        - Rejected by hooks: 247 (2.0%)
          - Auth: 25 (0.2%)
          - Rate Limit: 222 (1.8%)
```

## Implementation Phases

### Phase 1: Core Infrastructure (Week 1)

**Deliverables**:
1. Database migration for `hooks` table
2. Ecto schema `Plugboard.Hooks.Hook`
3. Context module `Plugboard.Hooks` with CRUD operations
4. `HookStore` GenServer for ETS caching
5. `HookNotifier` for PostgreSQL NOTIFY/LISTEN
6. Basic unit tests for hook CRUD
7. HTTPoison dependency added for external HTTP hooks

**Files to Create/Modify**:
- `priv/repo/migrations/YYYYMMDDHHMMSS_create_hooks_table.exs`
- `lib/plugboard/hooks/hook.ex`
- `lib/plugboard/hooks.ex`
- `lib/plugboard/hook_store.ex`
- `lib/plugboard/hook_notifier.ex`
- `mix.exs` (add HTTPoison dependency)
- `test/plugboard/hooks_test.exs`

### Phase 2: Hook Execution Engine (Week 2)

**Deliverables**:
1. `Plugboard.Hooks.Executor` module
2. Hook execution logic (sequential, body merging)
3. Mount point hook execution (via telephone)
4. HTTP URL hook execution (via HTTPoison)
5. Integration with `ProxyController`
6. Telemetry integration
7. Comprehensive integration tests

**Files to Create/Modify**:
- `lib/plugboard/hooks/executor.ex` (new)
- `lib/plugboard_web/controllers/proxy_controller.ex`
- `lib/plugboard/application.ex` (start HookStore, HookNotifier)
- `test/plugboard/hooks/executor_test.exs`
- `test/plugboard_web/controllers/proxy_controller_test.exs`

### Phase 3: API Endpoints (Week 2-3)

**Deliverables**:
1. Hook management API controller
2. API routes for hooks
3. Authorization checks (user must own path)
4. Hook testing endpoint (POST /api/hooks/:id/test)
5. Hook reordering endpoint
6. API documentation
7. API tests

**Files to Create/Modify**:
- `lib/plugboard_web/controllers/api/hook_controller.ex`
- `lib/plugboard_web/router.ex` (add hook routes)
- `test/plugboard_web/controllers/api/hook_controller_test.exs`

### Phase 4: Frontend UI (Week 3-4)

**Deliverables**:
1. Hooks LiveView page
2. Hook creation/edit form with target type selection
3. Hook list with visual flow diagram
4. Drag-and-drop reordering
5. Hook testing UI (interactive request/response viewer)
6. Execution stats and analytics display

**Files to Create**:
- `lib/plugboard_web/live/hooks_live/index.ex`
- `lib/plugboard_web/live/hooks_live/form_component.ex`
- `lib/plugboard_web/live/hooks_live/test_component.ex`
- `assets/js/hooks/drag_drop.js` (for reordering)

### Phase 5: Observability & Polish (Week 4)

**Deliverables**:
1. Hook execution logging (optional: persist to database)
2. Execution history/analytics dashboard
3. Dashboard metrics (success rates, latency percentiles)
4. Error notifications and alerts
5. Documentation updates (README, API docs, examples)
6. Performance optimization (caching, connection pooling)
7. End-to-end tests

**Files to Create/Modify**:
- `lib/plugboard/hooks/execution_log.ex` (optional)
- `lib/plugboard_web/live/dashboard_live.ex` (add hook metrics)
- `README.md` (hooks documentation section)
- `docs/HOOKS.md` (comprehensive hook guide with examples)
- `test/plugboard_web/integration/hooks_integration_test.exs`

## Testing Strategy

### Unit Tests

```elixir
# test/plugboard/hooks_test.exs
describe "create_hook/2" do
  test "creates mount_point hook with valid attributes"
  test "creates http_url hook with valid attributes"
  test "validates target_type constraint"
  test "validates execution_order uniqueness per path"
  test "validates allowed_status_codes format"
end

# test/plugboard/hooks/executor_test.exs
describe "execute_hooks/2" do
  test "executes hooks sequentially in order"
  test "merges hook responses at root level"
  test "stops on first non-whitelisted status code"
  test "handles hook timeout"
  test "handles hook unavailable error"
  test "skips hooks when list is empty"
  test "handles non-JSON hook responses gracefully"
  test "handles key conflicts (last write wins)"
end

describe "execute_mount_point_hook/3" do
  test "calls telephone for internal mount point"
  test "forwards correct payload to telephone"
  test "respects timeout configuration"
end

describe "execute_http_hook/3" do
  test "makes HTTP POST request to external URL"
  test "includes correct headers"
  test "handles HTTP timeout"
  test "handles connection refused"
end
```

### Integration Tests

```elixir
# test/plugboard_web/integration/hooks_integration_test.exs
test "full request flow with single hook" do
  # Setup: path, hook, mock hook backend
  # Execute: POST request to /call/users
  # Assert: Hook called, response merged, backend received merged body
end

test "full request flow with multiple hooks" do
  # Setup: 3 hooks in sequence
  # Execute: Request flows through all hooks
  # Assert: Each hook sees previous hook's additions
end

test "hook rejection stops request" do
  # Setup: Hook that returns 401
  # Execute: Request to backend
  # Assert: Backend never called, client receives 401 from hook
end

test "hook timeout returns 504" do
  # Setup: Hook with 1s timeout, mock slow response
  # Execute: Request
  # Assert: Returns 504 after timeout
end

test "HTTP hook execution" do
  # Setup: Hook targeting external HTTP URL
  # Use Bypass or Mock HTTP server
  # Assert: HTTP request made correctly
end
```

### Performance Tests

- Measure latency overhead of hook execution
- Test with 5+ chained hooks
- Load test with 1000 req/s
- Target: < 50ms total overhead for 3 hooks
- Memory usage should remain stable (no leaks)

## Security Considerations

1. **Hook Target Validation**: 
   - Mount point hooks: Only allow targeting existing, active mount points
   - HTTP URL hooks: Validate URL format, optionally restrict to allowlist of domains
   
2. **Authorization**: 
   - Users can only create hooks for paths they own (check `user_paths`)
   - Prevent SSRF: Optionally block internal IPs for HTTP hooks (127.0.0.1, 192.168.*, etc.)
   
3. **Body Size Limits**: 
   - Enforce max body size after merging (prevent memory exhaustion)
   - Limit merged body to `max_request_body_length` config
   
4. **Timeout Enforcement**: 
   - Hard limit hook timeouts (max 60s)
   - Total hook chain timeout should be configurable per path
   
5. **Header Filtering**: 
   - Only forward explicitly whitelisted headers
   - Strip sensitive headers by default (Authorization, Cookie unless explicitly forwarded)
   
6. **Audit Logging**: 
   - Log all hook configuration changes
   - Log hook rejections and failures
   
7. **Rate Limiting**: 
   - Consider per-hook rate limiting to prevent abuse
   - Prevent hooks from being called in loops

## Migration Path

### For Existing Deployments

1. Deploy database migration (creates `hooks` table)
2. Deploy application code (hooks disabled by default - no hooks configured)
3. Gradually add hooks to paths via API/UI
4. Monitor performance metrics and error rates
5. Adjust timeouts and configurations based on observability data

### Backward Compatibility

- Paths without hooks continue to work exactly as before (zero overhead)
- Hook execution only triggers if hooks exist for a path
- No breaking changes to existing API
- Existing telephone connections unaffected

## Open Questions / Future Enhancements

1. **Deep Merge Support**: Allow configuration for deep merging nested objects?
2. **Conditional Hooks**: Execute hooks based on conditions (HTTP method, header values, path patterns)?
3. **Hook Templates**: Predefined hook configurations for common patterns?
4. **Circuit Breaker**: Auto-disable hooks after N consecutive failures?
5. **Retry Logic**: Retry failed hook calls with exponential backoff?
6. **Response Transformation**: Allow hooks to modify final response to client?
7. **Async Post-Hooks**: Re-introduce post-hooks for audit logging use cases?
8. **Webhook Support**: Trigger webhooks on hook events (failure, slow response)?
9. **Hook Versioning**: Track changes to hook configurations over time?
10. **Body Transformation Language**: DSL for complex transformations (JSONPath, JQ-like)?

## Success Metrics

- Hook execution latency < 50ms p95 per hook
- Hook success rate > 99%
- Zero impact on paths without hooks (< 1ms overhead)
- UI allows creating hooks in < 2 minutes
- Test coverage > 90%
- No memory leaks during 24h load test
- Documentation with 5+ real-world examples

## Conclusion

This hooks feature transforms Plugboard from a simple reverse proxy into a powerful request processing pipeline. By executing hooks sequentially and merging their responses into the request body, backends receive enriched context without implementing complex auth/validation logic themselves. Support for both internal mount points and external HTTP endpoints provides maximum flexibility while maintaining the simplicity of the core proxy architecture.
