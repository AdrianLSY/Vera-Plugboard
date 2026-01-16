# Plugboard

**WebSocket-based reverse proxy server for the Vera-Stack**

[![Elixir](https://img.shields.io/badge/elixir-1.15+-purple.svg)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](../LICENSE)
[![CI](https://github.com/AdrianLSY/Vera-Plugboard/actions/workflows/ci.yml/badge.svg)](https://github.com/AdrianLSY/Vera-Plugboard/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/AdrianLSY/Vera-Plugboard/branch/main/graph/badge.svg)](https://codecov.io/gh/AdrianLSY/Vera-Plugboard)

---

## Overview

Plugboard is a reverse proxy server that routes HTTP requests through WebSocket tunnels to Telephone sidecars. It maintains a distributed registry of active connections and uses in-memory caching for O(1) path matching.

### Key Features

- **WebSocket Tunnels** - Persistent connections to Telephone sidecars
- **WebSocket Proxy** - Transparent WebSocket proxying to backend services
- **O(1) Path Matching** - ETS-backed route lookup with terminal mount strategy
- **Domain Affinity** - Domain-based routing with exact and wildcard matching
- **Request Hooks** - Middleware pipeline for pre-request processing
- **Distributed Registry** - CRDT-based clustering via Horde
- **Request Correlation** - UUID-based concurrent request handling
- **Automatic Failover** - Cluster-wide rebalancing and partition healing
- **Phoenix Channels** - Full Phoenix framework integration

---

## Quick Start

### Prerequisites

- Elixir 1.15+
- Erlang/OTP 26+
- PostgreSQL 14+

### Installation

```bash
# Clone the repository
cd Plugboard

# Install dependencies
mix deps.get

# Setup database
mix ecto.setup

# Start the server
mix phx.server
```

### Configuration

Create a `.env` file with required variables:

```bash
# Phoenix Server
SECRET_KEY_BASE=your_64_char_secret  # Generate with: mix phx.gen.secret
PHX_SERVER=true                      # Optional: Start server on boot (required for releases)
PHX_PORT=4000
PHX_HOST=localhost

# PostgreSQL Database
POSTGRES_USER=plugboard
POSTGRES_PASSWORD=plugboard
POSTGRES_DB=plugboard
POSTGRES_HOST=localhost
POSTGRES_PORT=5432                   # Optional: defaults to 5432
DB_POOL_SIZE=10
DB_QUERY_TIMEOUT=15000
DB_CONNECT_TIMEOUT=5000
ECTO_IPV6=false                      # Optional: Enable IPv6 for database

# Application Settings
MAX_REQUEST_BODY_SIZE=10485760       # Optional: Max request body (10MB default)
MOUNT_STORE_RECONCILE_INTERVAL=300000  # Optional: Path reconciliation (5 min default)

# Telephone Configuration
TELEPHONE_TOKEN_EXPIRY=3600          # Optional: Token expiry (1 hour default)
TELEPHONE_TOKEN_REFRESH_INTERVAL=1800  # Optional: Token refresh (30 min default)
TELEPHONE_HEARTBEAT_TIMEOUT_MS=60000   # Optional: Heartbeat timeout (60 sec default)

# Production Clustering (Optional)
DNS_CLUSTER_QUERY=                   # DNS query for clustering in Kubernetes
```

### Run

```bash
# Start PostgreSQL (if not running)
docker run -d \
  --name plugboard-db \
  -e POSTGRES_USER=plugboard \
  -e POSTGRES_PASSWORD=plugboard \
  -e POSTGRES_DB=plugboard \
  -p 6432:5432 \
  postgres:14

# Start Plugboard
iex -S mix phx.server
```

---

## How It Works

### Standard Proxy Flow (with `/call` prefix)

```
┌──────────────┐
│    Client    │
└──────┬───────┘
       │ HTTP Request: GET /call/api/users
       ▼
┌─────────────────────────────────────────────────────┐
│              Plugboard (:4000)                      │
│                                                     │
│  1. ProxyController receives request                │
│  2. MountStore.match("/api/users")                  │
│     → ETS lookup (O(1))                             │
│     → Finds mount: /call/api                        │
│  3. TelephoneRegistry.get_telephone(path_id)        │
│     → Horde registry lookup (round-robin)           │
│  4. Send {proxy_req, correlation_id, payload}       │
│     → Via process message to TelephoneChannel       │
│  5. Wait for {proxy_res, correlation_id, response}  │
│     → Timeout: request_timeout_ms (default: 60s)    │
└────────────┬────────────────────────────────────────┘
             │ WebSocket (Phoenix Channel)
             ▼
┌─────────────────────────────────────────────────────┐
│           Telephone Sidecar (WebSocket)             │
│                                                     │
│  1. Receives proxy_req message                      │
│  2. Forwards HTTP request to backend                │
│     → Path: /users (stripped /call/api prefix)      │
│  3. Receives HTTP response from backend             │
│  4. Sends proxy_res message back                    │
│     → Includes correlation_id for matching          │
└────────────┬────────────────────────────────────────┘
             │ HTTP
             ▼
┌─────────────────────────────────────────────────────┐
│              Backend Service (:3000)                │
│           GET /users → User data                    │
└─────────────────────────────────────────────────────┘
```

### Domain Affinity Flow (no `/call` prefix)

```
┌──────────────┐
│    Client    │
└──────┬───────┘
       │ HTTP Request: GET https://users.example.com/profile/123
       │ Host: users.example.com
       ▼
┌─────────────────────────────────────────────────────┐
│              Plugboard (:4000)                      │
│                                                     │
│  1. DomainAffinityRouter plug checks Host header    │
│  2. MountStore.match_by_domain("users.example.com") │
│     → ETS lookup (O(1))                             │
│     → Finds: users.example.com → /call/users        │
│  3. ProxyController.proxy_domain/2                  │
│  4. Forwards entire path to telephone               │
│     → Path: /profile/123 (no prefix stripping)      │
└────────────┬────────────────────────────────────────┘
             │ WebSocket (Phoenix Channel)
             ▼
┌─────────────────────────────────────────────────────┐
│           Telephone Sidecar (WebSocket)             │
│           Connected to /call/users                  │
│                                                     │
│  Forwards: GET /profile/123 → Backend               │
└─────────────────────────────────────────────────────┘
```

### Hooks Execution Flow (Request Middleware)

```
┌──────────────┐
│    Client    │
└──────┬───────┘
       │ HTTP Request: POST /call/api/orders
       │ Body: {"product_id": "123", "quantity": 2}
       ▼
┌─────────────────────────────────────────────────────┐
│              Plugboard (:4000)                      │
│                                                     │
│  1. ProxyController receives request                │
│  2. HookStore.get_hooks(path_id)                    │
│     → Returns hooks ordered by execution_order      │
│                                                     │
│  3. Hooks.Executor processes each hook:             │
│     ┌─────────────────────────────────────────┐     │
│     │ Hook 1: "Auth Validator" (order: 0)     │     │
│     │ Target: /call/auth/validate             │     │
│     │ → Sends request to auth telephone       │     │
│     │ → Response: {"user_id": "u123"}         │     │
│     │ → Merged into body                      │     │
│     └─────────────────────────────────────────┘     │
│     ┌─────────────────────────────────────────┐     │
│     │ Hook 2: "Inventory Check" (order: 1)    │     │
│     │ Target: https://inventory.internal/check│     │
│     │ → HTTP POST to external endpoint        │     │
│     │ → Response: {"in_stock": true}          │     │
│     │ → Merged into body                      │     │
│     └─────────────────────────────────────────┘     │
│                                                     │
│  4. Final body after hooks:                         │
│     {"product_id": "123", "quantity": 2,            │
│      "user_id": "u123", "in_stock": true}           │
│                                                     │
│  5. Forward to target telephone                     │
└────────────┬────────────────────────────────────────┘
             │ WebSocket (Phoenix Channel)
             ▼
┌─────────────────────────────────────────────────────┐
│           Telephone Sidecar (WebSocket)             │
│           Receives enriched request body            │
└─────────────────────────────────────────────────────┘
```

**Hook Rejection Flow:**

If a hook returns a non-whitelisted status code, the request is rejected immediately:

```
Hook returns 403 (not in allowed_status_codes [200, 201, 202, 204])
    → Request rejected
    → Client receives hook's response (status + body)
    → Subsequent hooks are NOT executed
    → Target backend is NOT called
```

### WebSocket Proxy Flow

Plugboard supports transparent WebSocket proxying, allowing clients to establish WebSocket connections that are forwarded through Telephone sidecars to backend services.

```
┌──────────────┐
│    Client    │
└──────┬───────┘
       │ WebSocket Upgrade: wss://api.example.com/websocket
       │ Sec-WebSocket-Protocol: graphql-ws
       ▼
┌─────────────────────────────────────────────────────┐
│              Plugboard (:4000)                      │
│                                                     │
│  1. WebSocketProxyPlug detects upgrade request      │
│  2. MountStore.match_by_domain("api.example.com")   │
│     → ETS lookup (O(1))                             │
│     → Finds: api.example.com → /call/api            │
│  3. TelephoneRegistry.get_telephone(path_id)        │
│     → Gets available telephone                      │
│  4. WebSockAdapter.upgrade() → ProxyHandler         │
│  5. ProxyHandler sends ws_connect to Telephone      │
└────────────┬────────────────────────────────────────┘
             │ Phoenix Channel (existing connection)
             ▼
┌─────────────────────────────────────────────────────┐
│           Telephone Sidecar                         │
│                                                     │
│  1. Receives ws_connect event                       │
│  2. Opens WebSocket to backend                      │
│     → wss://localhost:3000/websocket                │
│     → Negotiates subprotocol (graphql-ws)           │
│  3. Sends ws_connected back to Plugboard            │
│  4. Bidirectional frame forwarding:                 │
│     Client ←→ Plugboard ←→ Telephone ←→ Backend     │
└────────────┬────────────────────────────────────────┘
             │ WebSocket
             ▼
┌─────────────────────────────────────────────────────┐
│              Backend Service (:3000)                │
│           WebSocket endpoint /websocket             │
│           Subprotocol: graphql-ws                   │
└─────────────────────────────────────────────────────┘
```

**WebSocket Proxy Features:**
- Transparent subprotocol negotiation (graphql-ws, wamp, etc.)
- Binary and text frame support
- Works with path-based (`/call/api/ws`) and domain-based routing
- Same authentication/authorization as HTTP proxy
- Automatic cleanup on client/backend disconnect

---

## Architecture

### Core Components

**ProxyController** (`lib/plugboard_web/controllers/proxy_controller.ex`)
- Entry point for incoming HTTP requests at `/call/*path` or domain-based routes
- Performs ETS path lookup via `MountStore.match/1` (O(1))
- Retrieves Telephone process from `TelephoneRegistry` (round-robin across available telephones)
- Sends `{:proxy_request, caller_pid, correlation_id, request_payload}` to TelephoneChannel
- Waits for `{:proxy_res, correlation_id, response}` with configurable timeout
- Streams chunked responses back to clients when `chunked: true`
- Emits comprehensive telemetry events for monitoring

**TelephoneChannel** (`lib/plugboard_web/channels/telephone_channel.ex`)
- Manages WebSocket connections from Telephone sidecars via Phoenix Channels
- Authenticates connections using JWT tokens (from telephone_tokens table)
- Registers telephone process in Horde registry on join
- Receives `{:proxy_request, ...}` messages from ProxyController
- Forwards requests over WebSocket to Telephone sidecar
- Implements request correlation with UUIDs for concurrent requests
- Handles connection lifecycle, disconnection, and cleanup
- Updates `last_used_at` timestamp on telephone tokens

**MountStore** (`lib/plugboard/mount_store.ex`)
- GenServer maintaining two ETS tables: `:plugboard_mounts` and `:plugboard_domain_affinities`
- Loads mount points from PostgreSQL `paths` table on startup
- Provides O(1) path matching via `match/1` (longest prefix matching)
- Provides O(1) domain matching via `match_by_domain/1` (exact + wildcard)
- Listens for PostgreSQL NOTIFY events for real-time cache updates
- Periodic reconciliation to ensure consistency with database
- Handles domain normalization (lowercase, strip port)

**TelephoneRegistry** (`lib/plugboard/telephone_registry.ex`)
- Wrapper around Horde.Registry for distributed process registry
- Registers telephone channels by `path_id` on WebSocket join
- Supports multiple telephones per path (horizontal scaling)
- Round-robin selection via `get_telephone/1`
- CRDT-based for automatic cluster-wide failover
- Handles process crashes and network partitions

**Paths Context** (`lib/plugboard/paths.ex`)
- PostgreSQL-backed hierarchical path management
- Enforces terminal mount point constraint via database triggers
- Auto-computes `full_path` from parent hierarchy
- Manages user roles (owner, maintainer, viewer) via `user_paths` junction table
- Cascades `full_path` updates to all descendants
- Soft-delete support for paths

**TelephoneTokens Context** (`lib/plugboard/telephone_tokens.ex`)
- JWT token generation for telephone authentication
- SHA256 hash storage (tokens never stored in plain text)
- Configurable expiry via `TELEPHONE_TOKEN_EXPIRY`
- Token validation and revocation
- Tracks `last_used_at` for usage monitoring

**ServiceAccounts Context** (`lib/plugboard/service_accounts.ex`)
- API key generation for Token Vending Machine
- Enables auto-scaling scenarios (e.g., Kubernetes HPA)
- SHA256 hash storage (API keys never stored in plain text)
- Scoped to specific paths
- Role-based access control (owner/maintainer)

**DomainAffinities Context** (`lib/plugboard/domain_affinities.ex`)
- Maps custom domains to mount points
- Supports exact domains (`api.example.com`) and wildcards (`*.api.example.com`)
- Domain normalization and validation
- PostgreSQL NOTIFY triggers for real-time ETS updates
- Soft-delete support

**Hooks Context** (`lib/plugboard/hooks.ex`)
- Middleware management for pre-request processing
- Role-based access control (owner/maintainer required)
- Circular dependency detection for mount point hooks
- Soft-delete support with ordered execution

**Hooks.Executor** (`lib/plugboard/hooks/executor.ex`)
- Executes hooks sequentially by `execution_order`
- Supports two target types: internal mount points and external HTTP URLs
- Merges hook responses into request body at root level
- Rejects requests when hooks return non-whitelisted status codes
- Configurable timeout per hook (1ms - 60s)

**HookStore** (`lib/plugboard/hook_store.ex`)
- GenServer maintaining ETS table `:plugboard_hooks`
- Loads hooks from PostgreSQL on startup
- Provides O(1) lookups by `path_id`
- Listens for PostgreSQL NOTIFY events for real-time cache updates
- Periodic reconciliation with database

**HookNotifier** (`lib/plugboard/hook_notifier.ex`)
- PostgreSQL LISTEN/NOTIFY listener for hook changes
- Establishes dedicated PostgreSQL connection
- Automatic reconnection with exponential backoff (max 30s)
- Updates HookStore ETS table on notifications

**TokenCleanup** (`lib/plugboard/telephone_tokens/token_cleanup.ex`)
- GenServer that periodically cleans up expired telephone tokens
- Runs every hour to prevent unbounded table growth
- Prevents accumulation of stale token records

### Terminal Mount Strategy

Plugboard uses a **terminal mount point** strategy to avoid routing ambiguity:

**Valid Configurations:**

```
Root
├── /call/api (mount point ✓) - no children allowed
├── /call/users
│   ├── /call/users/v1 (mount point ✓) - terminal, no children
│   └── /call/users/v2 (mount point ✓) - terminal, no children
└── /call/admin (mount point ✓) - no children allowed
```

**Invalid Configurations:**

```
# Cannot mark as mount if path has children
Root
└── /call/api (NOT a mount point)
    ├── /call/api/v1
    └── /call/api/v2

# ❌ Trying to mark /call/api as mount point
# Error: "Cannot mark path as mount point when it has children"

# Cannot create child under existing mount point
Root
└── /call/api (mount point ✓)

# ❌ Trying to create /call/api/v2 as child
# Error: "Cannot create child path under a mount point"
```

**Enforcement Mechanisms:**

1. **Database Triggers:**
   - `prevent_mount_when_has_children()` - Blocks marking paths with children as mount points
   - `prevent_child_under_mount()` - Blocks creating children under mount points
   - Uses `FOR UPDATE` locks to prevent race conditions

2. **Application Layer:**
   - `Paths.can_mark_as_mount?/1` - Checks if path has children before toggling mount status
   - Web UI disables mount toggle for paths with children

3. **Benefits:**
   - **Unambiguous routing**: Each request path maps to exactly one mount point
   - **Predictable behavior**: Longest prefix matching always finds the correct mount
   - **Clear ownership**: Each mount point represents exactly one backend service

**Path Matching Example:**

```elixir
# Given mount points: /call/api and /call/users/v1

MountStore.match("/api/health")
# → {:ok, {"/call/api", "/health", mount_id}}

MountStore.match("/users/v1/profile")  
# → {:ok, {"/call/users/v1", "/profile", mount_id}}

MountStore.match("/users/v2/profile")
# → {:error, :not_found}  # No mount at /call/users/v2
```

### Request Correlation

Each proxied request receives a unique correlation ID, allowing multiple concurrent requests over a single WebSocket connection:

```elixir
%{
  correlation_id: UUID.uuid4(),
  method: "GET",
  path: "/api/users",
  headers: [...],
  body: <<...>>
}
```

### Database Schema

**paths table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `parent_id` | UUID | Reference to parent path (NULL for root) |
| `path` | String | Path segment (e.g., `api`, `users`) |
| `full_path` | String | Complete path from root (e.g., `/call/api/users`) - auto-computed |
| `mount_point` | Boolean | Whether this path accepts telephone connections |
| `request_timeout_ms` | Integer | Max time to wait for telephone response (default: 60000) |
| `connect_timeout_ms` | Integer | Max time to wait for telephone connection (default: 5000) |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |
| `deleted_at` | Timestamp | Soft delete timestamp |

**Constraints:**
- Path segments must be alphanumeric with hyphens, underscores, dots only
- No forward slashes allowed in path segments
- Unique sibling paths (same parent cannot have duplicate child names)
- Globally unique full_path values
- Mount points cannot have children (terminal mount strategy)
- Children cannot be created under mount points

**telephone_tokens table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `path_id` | UUID | Reference to paths table |
| `user_id` | UUID | Reference to users table (creator) |
| `token_hash` | String | SHA256 hash of JWT token |
| `name` | String | Optional token name |
| `description` | String | Optional description |
| `expires_at` | Timestamp | Token expiration time |
| `revoked_at` | Timestamp | Revocation timestamp (NULL if active) |
| `last_used_at` | Timestamp | Last authentication time |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |

**service_accounts table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `user_id` | UUID | Reference to users table (owner) |
| `path_id` | UUID | Reference to paths table |
| `name` | String | Service account name |
| `description` | String | Optional description |
| `api_key_hash` | String | SHA256 hash of API key |
| `revoked_at` | Timestamp | Revocation timestamp (NULL if active) |
| `last_used_at` | Timestamp | Last use time |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |

**domain_affinities table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `domain` | String | Domain name (e.g., `api.example.com` or `*.example.com`) |
| `path_id` | UUID | Reference to paths table (must be mount point) |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |
| `deleted_at` | Timestamp | Soft delete timestamp |

**Constraints:**
- Domain must be valid format (alphanumeric, hyphens, dots, optional wildcard prefix)
- Unique active domains (one domain can only map to one path)
- Associated path must be a mount point

**hooks table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `path_id` | UUID | Reference to paths table (cascade delete) |
| `name` | String | Hook name (required) |
| `description` | Text | Optional description |
| `target_type` | String | `mount_point` or `http_url` |
| `target_path_id` | UUID | Reference to target path (for mount_point type) |
| `target_url` | Text | External URL (for http_url type) |
| `execution_order` | Integer | Order of execution (unique per path, default: 0) |
| `timeout_ms` | Integer | Timeout in milliseconds (default: 5000, max: 60000) |
| `allowed_status_codes` | JSONB | Status codes that allow request to proceed (default: [200, 201, 202, 204]) |
| `forward_headers` | JSONB | List of headers to forward from original request |
| `forward_query_params` | Boolean | Whether to forward query parameters (default: false) |
| `deleted_at` | Timestamp | Soft delete timestamp |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |

**Constraints:**
- `target_type` must be `mount_point` or `http_url`
- If `target_type = mount_point`: `target_path_id` required, `target_url` must be null
- If `target_type = http_url`: `target_url` required, `target_path_id` must be null
- `timeout_ms` must be between 1 and 60000
- `execution_order` must be >= 0 and unique per path
- Circular dependencies are prevented at application level

**user_paths table** (junction table)

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `user_id` | UUID | Reference to users table |
| `path_id` | UUID | Reference to paths table |
| `role` | String | User role: `owner`, `maintainer`, or `viewer` |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |

**Notes:**
- When a path is created, the creator is automatically assigned as `owner`
- Roles are inherited: access to a path grants access to all descendants
- Multiple users can have different roles on the same path

---

## Docker

### Build Image

```bash
docker build -t plugboard:latest .
```

### Run Container

```bash
docker run --rm -it \
  -e SECRET_KEY_BASE=$SECRET_KEY_BASE \
  -e PHX_SERVER=true \
  -e PHX_PORT=4000 \
  -e PHX_HOST=localhost \
  -e POSTGRES_USER=plugboard \
  -e POSTGRES_PASSWORD=plugboard \
  -e POSTGRES_DB=plugboard \
  -e POSTGRES_HOST=db \
  -e POSTGRES_PORT=5432 \
  -e MAX_REQUEST_BODY_SIZE=10485760 \
  -e TELEPHONE_TOKEN_EXPIRY=3600 \
  -p 4000:4000 \
  plugboard:latest
```

---

## Configuration Reference

### Environment Variables

**All configuration variables are required unless marked optional.**

| Variable                                       | Description                           | Example Value                         | Required |
|------------------------------------------------|---------------------------------------|---------------------------------------|----------|
| `SECRET_KEY_BASE`                              | Secret key for signing (min 64 chars) | Generate with `mix phx.gen.secret`    | ✅       |
| `PHX_PORT`                                     | HTTP port                             | `4000`                                | ✅       |
| `PHX_HOST`                                     | Hostname for URL generation           | `localhost`                           | ✅       |
| `POSTGRES_USER`                                | Database username                     | `plugboard`                           | ✅       |
| `POSTGRES_PASSWORD`                            | Database password                     | `plugboard`                           | ✅       |
| `POSTGRES_DB`                                  | Database name                         | `plugboard`                           | ✅       |
| `POSTGRES_HOST`                                | Database host                         | `localhost`                           | ✅       |
| `DB_POOL_SIZE`                                 | Connection pool size                  | `10`                                  | ✅       |
| `DB_QUERY_TIMEOUT`                             | Max query time (ms)                   | `15000`                               | ✅       |
| `DB_CONNECT_TIMEOUT`                           | Max connection time (ms)              | `5000`                                | ✅       |
| `PHX_SERVER`                                   | Start Phoenix server on boot          | `true`                                | ❌       |
| `POSTGRES_PORT`                                | Database port                         | `5432`                                | ❌       |
| `MAX_REQUEST_BODY_SIZE`                        | Max request body (bytes)              | `10485760` (10MB)                     | ❌       |
| `MOUNT_STORE_RECONCILE_INTERVAL`               | Path reconciliation interval (ms)     | `300000` (5 min)                      | ❌       |
| `TELEPHONE_TOKEN_EXPIRY`                       | Token expiry time (seconds)           | `3600` (1 hour)                       | ❌       |
| `TELEPHONE_TOKEN_REFRESH_INTERVAL`             | Token refresh interval (seconds)      | `1800` (30 min)                       | ❌       |
| `TELEPHONE_HEARTBEAT_TIMEOUT_MS`               | Heartbeat timeout (milliseconds)      | `60000` (60 sec)                      | ❌       |
| `DNS_CLUSTER_QUERY`                            | DNS query for clustering              | `plugboard.default.svc.cluster.local` | ❌       |
| `ECTO_IPV6`                                    | Enable IPv6 for database              | `false`                               | ❌       |
| `WEBSOCKET_PROXY_ENABLED`                      | Enable WebSocket proxying             | `true`                                | ❌       |
| `WEBSOCKET_CONNECT_TIMEOUT_MS`                 | Backend WebSocket connect timeout     | `5000` (5 sec)                        | ❌       |
| `WEBSOCKET_MAX_FRAME_SIZE`                     | Max WebSocket frame size (bytes)      | `1048576` (1MB)                       | ❌       |
| `WEBSOCKET_IDLE_TIMEOUT_MS`                    | WebSocket idle timeout                | `300000` (5 min)                      | ❌       |

---

## API Reference

All API endpoints require authentication via session cookies (web UI) or Bearer tokens (programmatic access).

### Path Management

Paths are managed through the **web UI** at `/paths`. There is no REST API for path CRUD operations.

**Web UI Routes:**
- `GET /paths` - View and manage path hierarchy
- `GET /paths/:path_id/tokens` - Manage tokens, service accounts, domain affinities, and hooks for a path

**Path Operations (UI only):**
- Create child paths under a parent
- Edit path names (triggers full_path recalculation for all descendants)
- Toggle mount point status (only for paths without children)
- Delete paths (requires confirmation with full path)

### Telephone Token Management

Telephone tokens are JWT tokens used by Telephone sidecars to authenticate WebSocket connections.

**Create Token**

```http
POST /api/paths/:path_id/tokens
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "name": "production-token",           # optional
  "description": "Production server"    # optional
}
```

**Response:**
```json
{
  "token": "eyJhbGc...",  // JWT token - store securely, cannot be retrieved again
  "id": "uuid",
  "path": "/call/api",
  "expires_at": "2025-12-31T23:59:59Z",
  "name": "production-token",
  "description": "Production server",
  "message": "Store this token securely. It cannot be retrieved again."
}
```

**List Tokens for Path**

```http
GET /api/paths/:path_id/tokens
Authorization: Bearer <session_token>
```

**Response:**
```json
{
  "tokens": [
    {
      "id": "uuid",
      "name": "production-token",
      "description": "Production server",
      "expires_at": "2025-12-31T23:59:59Z",
      "last_used_at": "2025-11-17T10:30:00Z",
      "created_at": "2025-11-01T00:00:00Z"
    }
  ]
}
```

**Revoke Token**

```http
DELETE /tokens/:id
Authorization: Bearer <session_token>
```

**Authorization:**
- User must have `owner` or `maintainer` role on the path

### Service Account Management

Service accounts provide API keys for the Token Vending Machine API, enabling auto-scaling scenarios.

**Create Service Account**

```http
POST /api/paths/:path_id/service-accounts
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "name": "k8s-autoscaler",
  "description": "Kubernetes HPA integration"  # optional
}
```

**Response:**
```json
{
  "api_key": "sa_...",  // Store securely, cannot be retrieved again
  "id": "uuid",
  "name": "k8s-autoscaler",
  "description": "Kubernetes HPA integration",
  "path_id": "uuid",
  "message": "Store this API key securely. It cannot be retrieved again."
}
```

**List Service Accounts for Path**

```http
GET /api/paths/:path_id/service-accounts
Authorization: Bearer <session_token>
```

**List All Service Accounts for User**

```http
GET /api/service-accounts
Authorization: Bearer <session_token>
```

**Revoke Service Account**

```http
DELETE /service-accounts/:id
Authorization: Bearer <session_token>
```

**Authorization:**
- User must have `owner` or `maintainer` role on the path

### Token Vending Machine API

Generate short-lived telephone tokens programmatically using a service account API key. Used for auto-scaling scenarios.

**Generate Token**

```http
POST /api/token-vending/generate
Content-Type: application/json
X-API-Key: <service_account_api_key>

{
  "path_id": "uuid"
}
```

**Response:**
```json
{
  "token": "eyJhbGc...",  // JWT token valid for TELEPHONE_TOKEN_EXPIRY seconds
  "expires_at": "2025-11-17T11:30:00Z",
  "path": "/call/api"
}
```

**Notes:**
- No session authentication required
- Uses `X-API-Key` header with service account API key
- Generated tokens have the same expiry as manually created tokens

### Domain Affinity Management

Map custom domains to mount points, enabling domain-based routing without the `/call` prefix.

**Create Domain Affinity**

```http
POST /api/paths/:path_id/domain-affinities
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "domain": "users.example.com"
}
```

**Examples:**
- Exact domain: `"domain": "api.example.com"`
- Wildcard domain: `"domain": "*.api.example.com"`

**Response:**
```json
{
  "id": "uuid",
  "domain": "users.example.com",
  "path_id": "uuid",
  "inserted_at": "2025-11-17T10:00:00Z"
}
```

**List Domain Affinities for Path**

```http
GET /api/paths/:path_id/domain-affinities
Authorization: Bearer <session_token>
```

**Response:**
```json
{
  "domain_affinities": [
    {
      "id": "uuid",
      "domain": "users.example.com",
      "path_id": "uuid",
      "inserted_at": "2025-11-17T10:00:00Z",
      "updated_at": "2025-11-17T10:00:00Z"
    }
  ]
}
```

**Delete Domain Affinity**

```http
DELETE /api/domain-affinities/:id
Authorization: Bearer <session_token>
```

**Authorization:**
- User must have `owner` or `maintainer` role for the path
- Path must be a mount point
- Domain names are automatically normalized (lowercased, port stripped)

### Hook Management

Hooks are middleware that process requests before they reach the target backend. They execute sequentially and can enrich requests with additional data or reject requests based on validation.

**Create Hook**

```http
POST /api/paths/:path_id/hooks
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "name": "Auth Validator",
  "description": "Validates user authentication",
  "target_type": "mount_point",
  "target_path_id": "uuid-of-auth-service",
  "execution_order": 0,
  "timeout_ms": 5000,
  "allowed_status_codes": [200, 201],
  "forward_headers": ["authorization", "x-request-id"],
  "forward_query_params": false
}
```

**Alternative: External HTTP Target**

```json
{
  "name": "External Validator",
  "target_type": "http_url",
  "target_url": "https://validator.example.com/check",
  "execution_order": 1,
  "timeout_ms": 3000
}
```

**Response:**
```json
{
  "id": "uuid",
  "name": "Auth Validator",
  "description": "Validates user authentication",
  "target_type": "mount_point",
  "target_path_id": "uuid-of-auth-service",
  "target_url": null,
  "execution_order": 0,
  "timeout_ms": 5000,
  "allowed_status_codes": [200, 201],
  "forward_headers": ["authorization", "x-request-id"],
  "forward_query_params": false,
  "created_at": "2025-11-18T10:00:00Z"
}
```

**List Hooks for Path**

```http
GET /api/paths/:path_id/hooks
Authorization: Bearer <session_token>
```

**Response:**
```json
{
  "hooks": [
    {
      "id": "uuid",
      "name": "Auth Validator",
      "description": "Validates user authentication",
      "target_type": "mount_point",
      "target_path_id": "uuid",
      "target_path": "/call/auth",
      "target_url": null,
      "execution_order": 0,
      "timeout_ms": 5000,
      "allowed_status_codes": [200, 201],
      "forward_headers": ["authorization"],
      "forward_query_params": false,
      "created_at": "2025-11-18T10:00:00Z",
      "updated_at": "2025-11-18T10:00:00Z"
    }
  ]
}
```

**Get Single Hook**

```http
GET /api/hooks/:id
Authorization: Bearer <session_token>
```

**Update Hook**

```http
PUT /api/hooks/:id
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "name": "Updated Name",
  "timeout_ms": 10000,
  "allowed_status_codes": [200, 201, 202]
}
```

**Delete Hook**

```http
DELETE /api/hooks/:id
Authorization: Bearer <session_token>
```

**Response:**
```json
{
  "message": "Hook deleted successfully"
}
```

**Reorder Hooks**

```http
PATCH /api/paths/:path_id/hooks/reorder
Content-Type: application/json
Authorization: Bearer <session_token>

{
  "hooks": [
    {"id": "hook-uuid-1", "execution_order": 0},
    {"id": "hook-uuid-2", "execution_order": 1},
    {"id": "hook-uuid-3", "execution_order": 2}
  ]
}
```

**Response:**
```json
{
  "hooks": [
    {"id": "hook-uuid-1", "execution_order": 0},
    {"id": "hook-uuid-2", "execution_order": 1},
    {"id": "hook-uuid-3", "execution_order": 2}
  ]
}
```

**Authorization:**
- User must have `owner` or `maintainer` role on the path
- Path must exist and not be deleted
- For `mount_point` targets: target path must exist and be a mount point
- Circular dependencies are automatically detected and rejected

**Hook Execution Behavior:**
- Hooks execute in `execution_order` (ascending)
- Each hook receives the accumulated request body from previous hooks
- Hook responses are merged at root level (`Map.merge/2`)
- If a hook returns a status not in `allowed_status_codes`, the request is rejected
- On rejection, the client receives the hook's response; subsequent hooks and backend are not called

### Proxy Routes

**Standard Proxy (with `/call` prefix)**

```http
GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD /call/*path
```

Routes requests to the appropriate mount point based on longest prefix match.

**Example:**
- Request: `GET /call/api/users/123`
- Mount point: `/call/api` → Telephone
- Forwarded path: `/users/123`

**Domain-Based Proxy (no `/call` prefix)**

```http
GET|POST|PUT|PATCH|DELETE|OPTIONS|HEAD /*path
Host: <domain_with_affinity>
```

Routes requests based on domain affinity mapping.

**Example:**
- Request: `GET https://users.example.com/profile/123`
- Domain affinity: `users.example.com` → `/call/users`
- Forwarded path: `/profile/123`

**Notes:**
- Domain routing only works if no other route matches first
- Admin routes (UI, API) take precedence over domain routing
- Returns 404 if domain has no affinity configured

---

## Features

### Routing & Path Matching
- O(1) ETS-backed path lookup
- Terminal mount point strategy (no ambiguous routes)
- Longest prefix matching
- Automatic path normalization

### Domain Affinity
- Map custom domains to mount points (e.g., `users.example.com` → `/call/users`)
- Bypass `/call` prefix for cleaner URLs
- Support for exact domain matching (`api.example.com`)
- Support for wildcard domains (`*.example.com`)
- O(1) domain lookup via ETS cache
- Real-time updates via PostgreSQL NOTIFY/LISTEN
- Web UI for managing domain affinities per mount point

**Example Use Cases:**
```bash
# Traditional routing
https://plugboard.example.com/call/api/users/123

# With domain affinity
https://api.example.com/users/123  # Routes to /call/api mount point
```

**How It Works:**
1. Configure domain affinity: `users.example.com` → Mount point `/call/users`
2. Request arrives at `users.example.com/profile/123`
3. Domain router matches domain → mount point
4. Request forwarded to telephone: `/profile/123`
5. Admin domain (`plugboard.example.com`) continues working normally

**Wildcard Support:**
- `*.api.example.com` matches `v1.api.example.com`, `v2.api.example.com`, etc.
- Most specific match wins: exact domain > wildcard > no match

### Request Hooks & Middleware
- Pre-request processing pipeline with sequential execution
- Target internal mount points (via telephone) or external HTTP endpoints
- Response merging at root level into request body
- Status code whitelisting for request acceptance/rejection
- Configurable timeout per hook (1ms - 60s)
- Header forwarding from original request
- Query parameter forwarding option
- Circular dependency detection for mount point hooks
- Real-time cache updates via PostgreSQL NOTIFY
- ETS-backed O(1) hook lookups by path

**Example Use Cases:**
```bash
# Authentication validation before processing
Hook 1: POST /call/auth/validate → Returns user context

# Rate limiting check
Hook 2: POST https://ratelimit.internal/check → Returns quota info

# Request enrichment with external data
Hook 3: POST /call/inventory/lookup → Returns stock levels

# All responses merged into final request body
```

### WebSocket Proxy
- Transparent WebSocket proxying through Telephone sidecars to backend services
- Works with both path-based (`/call/api/websocket`) and domain-based routing
- Transparent subprotocol negotiation (passes client's `Sec-WebSocket-Protocol` to backend)
- Binary and text frame support with base64 encoding over Phoenix Channels
- Per-connection isolation with unique connection IDs
- Automatic cleanup on client disconnect, backend disconnect, or telephone disconnect
- Configurable connect timeout, idle timeout, and max frame size
- ETS-based connection registry for monitoring and telemetry

**Example Use Cases:**
```bash
# WebSocket with path-based routing
wss://plugboard.example.com/call/api/websocket

# WebSocket with domain affinity
wss://api.example.com/websocket

# With subprotocol negotiation
wss://api.example.com/graphql  # Sec-WebSocket-Protocol: graphql-ws
```

**How It Works:**
1. Client sends WebSocket upgrade request to Plugboard
2. `WebSocketProxyPlug` detects upgrade, matches path/domain to mount point
3. Plugboard upgrades connection and spawns `ProxyHandler`
4. `ProxyHandler` sends `ws_connect` to Telephone via existing Phoenix Channel
5. Telephone opens WebSocket to backend, sends `ws_connected` back
6. Bidirectional frame forwarding: Client ↔ Plugboard ↔ Telephone ↔ Backend

**Configuration:**
- `WEBSOCKET_PROXY_ENABLED` - Enable/disable WebSocket proxying (default: `true`)
- `WEBSOCKET_CONNECT_TIMEOUT_MS` - Timeout for backend connection (default: `5000`)
- `WEBSOCKET_MAX_FRAME_SIZE` - Maximum frame size in bytes (default: `1048576`)
- `WEBSOCKET_IDLE_TIMEOUT_MS` - Idle timeout before closing (default: `300000`)

### Connection Management
- WebSocket connections to Telephone sidecars
- Automatic reconnection handling
- JWT token generation and validation
- Automatic token refresh at half-life

### Clustering & Distribution
- libcluster for automatic cluster formation
- DNS-based discovery in Kubernetes
- Horde CRDT-based process registry
- Automatic failover and rebalancing
- Partition healing

### Request Handling
- UUID-based request correlation
- Concurrent request support over single WebSocket
- Streaming responses
- Configurable request body size limits

### Data Management
- PostgreSQL-backed mount point storage
- ETS cache for high-performance lookups
- Soft-delete support
- Automatic cache synchronization

---

## Development

### Project Structure

```
Plugboard/
├── lib/
│   ├── plugboard/
│   │   ├── mount_store.ex        # Route storage & ETS cache
│   │   ├── mount_notifier.ex     # PostgreSQL NOTIFY listener for mounts
│   │   ├── hooks.ex              # Hooks context module
│   │   ├── hooks/
│   │   │   ├── hook.ex           # Hook schema
│   │   │   └── executor.ex       # Hook execution engine
│   │   ├── hook_store.ex         # Hook ETS cache
│   │   ├── hook_notifier.ex      # PostgreSQL NOTIFY listener for hooks
│   │   └── telephone_tokens/
│   │       └── token_cleanup.ex  # Periodic token cleanup
│   └── plugboard_web/
│       ├── endpoint.ex                     # Phoenix endpoint (HTTP/WebSocket)
│       ├── router.ex                       # Route definitions
│       ├── telemetry.ex                    # Telemetry metrics
│       ├── gettext.ex                      # I18n
│       ├── user_auth.ex                    # Authentication plugs
│       │
│       ├── channels/                       # Phoenix Channels (WebSocket)
│       │   ├── telephone_channel.ex        # Telephone WebSocket handler
│       │   └── telephone_socket.ex         # Telephone socket config
│       │
│       ├── controllers/                    # HTTP controllers
│       │   ├── page_controller.ex          # Home page
│       │   ├── proxy_controller.ex         # Proxy request handler
│       │   ├── user_session_controller.ex  # Login/logout
│       │   ├── error_html.ex               # HTML error pages
│       │   ├── error_json.ex               # JSON error responses
│       │   └── api/                        # API endpoints
│       │       ├── telephone_token_controller.ex
│       │       ├── service_account_controller.ex
│       │       ├── token_vending_controller.ex
│       │       ├── domain_affinity_controller.ex
│       │       └── hook_controller.ex      # Hook CRUD API
│       │
│       ├── live/                           # LiveView pages
│       │   ├── paths_live/
│       │   │   └── index.ex                # Path hierarchy management UI
│       │   ├── path_tokens_live/
│       │   │   └── index.ex                # Token/service account/domain/hooks UI
│       │   └── user_live/                  # User auth LiveViews
│       │       ├── registration.ex
│       │       ├── login.ex
│       │       ├── confirmation.ex
│       │       └── settings.ex
│       │
│       ├── components/                     # Reusable UI components
│       │   ├── core_components.ex          # Base UI components
│       │   └── layouts.ex                  # Page layouts
│       │
│       ├── plugs/                          # Custom plugs
│       │   ├── validate_path.ex            # Path validation (traversal protection)
│       │   ├── domain_affinity_router.ex   # Domain-based routing plug
│       │   └── parsers.ex                  # Runtime request body size configuration
│       │
│       └── http_error.ex                   # Error response helper
│
├── priv/repo/
│   ├── migrations/                         # Database migrations
│   │   ├── *_create_users_auth_tables.exs
│   │   ├── *_create_paths_table.exs
│   │   ├── *_create_user_paths_table.exs
│   │   ├── *_add_query_optimization_indexes.exs
│   │   ├── *_create_telephone_tokens_table.exs
│   │   ├── *_add_timeout_fields_to_paths.exs
│   │   ├── *_add_mount_notify_trigger.exs
│   │   ├── *_remove_obsolete_user_columns_from_paths.exs
│   │   ├── *_create_service_accounts_table.exs
│   │   ├── *_add_name_to_telephone_tokens.exs
│   │   ├── *_create_domain_affinities_table.exs
│   │   └── *_create_hooks_table.exs        # Hooks with NOTIFY trigger
│   └── seeds.exs                           # Seed data
│
├── test/                                   # Test suite
│   ├── plugboard/                          # Context tests
│   │   ├── accounts_test.exs
│   │   ├── paths_test.exs
│   │   ├── paths_concurrent_test.exs
│   │   ├── paths/
│   │   │   └── user_path_test.exs
│   │   ├── telephone_tokens_test.exs
│   │   ├── telephone_tokens/
│   │   │   └── token_cleanup_test.exs
│   │   ├── service_accounts_test.exs
│   │   ├── domain_affinities_test.exs
│   │   ├── domain_affinities/
│   │   │   └── domain_affinity_test.exs
│   │   ├── hooks_test.exs
│   │   ├── hooks/
│   │   │   ├── hook_test.exs
│   │   │   └── executor_test.exs
│   │   ├── mount_store_test.exs
│   │   ├── mount_notifier_test.exs
│   │   ├── hook_store_test.exs
│   │   ├── hook_notifier_test.exs
│   │   ├── cluster_connector_test.exs
│   │   ├── telephone_registry_test.exs
│   │   └── distributed_registry_test.exs
│   ├── plugboard_web/                      # Web tests
│   │   ├── user_auth_test.exs
│   │   ├── http_error_test.exs
│   │   ├── controllers/
│   │   │   ├── proxy_controller_test.exs
│   │   │   ├── page_controller_test.exs
│   │   │   ├── page_html_test.exs
│   │   │   ├── user_session_controller_test.exs
│   │   │   ├── error_html_test.exs
│   │   │   ├── error_json_test.exs
│   │   │   └── api/
│   │   │       ├── telephone_token_controller_test.exs
│   │   │       ├── service_account_controller_test.exs
│   │   │       ├── token_vending_controller_test.exs
│   │   │       ├── domain_affinity_controller_test.exs
│   │   │       └── hook_controller_test.exs
│   │   ├── channels/
│   │   │   ├── telephone_channel_test.exs
│   │   │   └── telephone_socket_test.exs
│   │   ├── components/
│   │   │   └── core_components_test.exs
│   │   ├── live/
│   │   │   ├── paths_live/
│   │   │   │   ├── index_test.exs
│   │   │   │   └── user_workflow_test.exs
│   │   │   ├── path_tokens_live/
│   │   │   │   └── index_test.exs
│   │   │   └── user_live/
│   │   │       ├── settings_test.exs
│   │   │       ├── registration_test.exs
│   │   │       ├── login_test.exs
│   │   │       └── confirmation_test.exs
│   │   └── plugs/
│   │       ├── validate_path_test.exs
│   │       └── domain_affinity_router_test.exs
│   └── support/                            # Test helpers
│
├── config/                                 # Configuration
│   ├── config.exs                          # Base config
│   ├── dev.exs                             # Development
│   ├── test.exs                            # Test environment
│   ├── prod.exs                            # Production
│   └── runtime.exs                         # Runtime config (env vars)
│
├── assets/                                 # Frontend assets (if any)
├── .formatter.exs                          # Code formatter config
├── mix.exs                                 # Project dependencies
└── mix.lock                                # Dependency lock file
```

### Running Tests

```bash
# Run all tests
mix test

# Run with coverage
mix test --cover

# Run specific test file
mix test test/plugboard/mount_store_test.exs
```

---

## Clustering

Plugboard supports multi-node clustering via **libcluster**:

**DNS-based Discovery (Kubernetes)**

```elixir
config :libcluster,
  topologies: [
    dns_poll: [
      strategy: Cluster.Strategy.DNSPoll,
      config: [
        query: System.get_env("DNS_CLUSTER_QUERY"),
        interval: 5_000
      ]
    ]
  ]
```

**Features:**
- Gossip protocol for membership
- Automatic partition healing
- CRDT-based state synchronization via Horde
- Consistent hashing for connection distribution

---

## Documentation

- **[AGENTS.md](AGENTS.md)** - Development conventions and Phoenix guidelines
- **[CLAUDE.md](CLAUDE.md)** - High-level system overview for AI assistants

---

## License

Licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

---

## Related Projects

- **[Vera Telephone](https://github.com/AdrianLSY/Vera-Telephone)** - The WebSocket sidecar component
- **[Vera Reverse Proxy](https://github.com/AdrianLSY/Vera-Reverse-Proxy)** - The complete technology stack

---
