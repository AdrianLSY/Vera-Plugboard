# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important: Read AGENTS.md First

**Always read `AGENTS.md` before making changes.** It is the development reference/bible containing Phoenix 1.8 conventions, Elixir guidelines, LiveView patterns, authentication handling, and UI/UX standards for this project.

## Project Overview

Plugboard is a WebSocket-based reverse proxy server for the Vera-Stack. It routes HTTP requests and WebSocket connections through tunnels to Telephone sidecars using:
- ETS-backed O(1) path matching with terminal mount strategy
- CRDT-based distributed registry via Horde
- Phoenix Channels for WebSocket communication
- UUID-based request correlation for concurrent request handling
- WebSocket proxy support for real-time bidirectional communication

## Build & Development Commands

```bash
# Install dependencies and setup
mix setup                    # deps.get + ecto.setup + assets

# Database operations
mix ecto.setup               # create + migrate + seeds
mix ecto.reset               # drop + setup
mix ecto.migrate

# Run server
mix phx.server               # Start Phoenix server
iex -S mix phx.server        # Start with IEx shell

# Run tests
mix test                     # Run all tests (auto-migrates)
mix test test/path/file.exs  # Run specific test file
mix test --failed            # Re-run failed tests
mix test --cover             # Run with coverage

# Pre-commit validation (run before committing)
mix precommit                # compile --warnings-as-errors + deps.unlock --unused + format + test
```

## Architecture

### Core Components (lib/plugboard/)

- **MountStore** (`mount_store.ex`) - PostgreSQL-backed route storage with ETS cache. Enforces terminal mount point constraint (no ambiguous child routes).
- **DistributedRegistry** (`distributed_registry.ex`) - Horde-based distributed process registry for cluster-wide telephone tracking.
- **TelephoneRegistry** (`telephone_registry.ex`) - Compatibility shim delegating to DistributedRegistry.
- **MountNotifier** (`mount_notifier.ex`) - PostgreSQL NOTIFY/LISTEN for real-time mount point updates.
- **ClusterConnector** (`cluster_connector.ex`) - Syncs libcluster events with Horde for cluster membership.
- **HookStore** (`hook_store.ex`) - ETS-backed cache for hooks with O(1) lookups by path_id.
- **HookNotifier** (`hook_notifier.ex`) - PostgreSQL LISTEN/NOTIFY for real-time hook updates.
- **Hooks** (`hooks.ex`) - Context for managing request hooks/middleware with role-based access.
- **Hooks.Executor** (`hooks/executor.ex`) - Executes hooks sequentially, merges responses into request body. Includes SSRF protection and header blocklist.
- **TokenCleanup** (`telephone_tokens/token_cleanup.ex`) - Periodic cleanup of expired telephone tokens (hourly).
- **WebSocketProxyRegistry** (`websocket_proxy_registry.ex`) - ETS-based registry tracking active WebSocket proxy connections.
- **Crypto** (`crypto.ex`) - Cryptographic utilities: Argon2 hashing for tokens/API keys, HKDF key derivation for JWT signing, constant-time secure comparison.
- **RateLimiter** (`rate_limiter.ex`) - ETS-based rate limiting GenServer with configurable windows and limits.

### Web Layer (lib/plugboard_web/)

- **ProxyController** (`controllers/proxy_controller.ex`) - Entry point for proxied HTTP requests. Routes `/call/*path` through WebSocket tunnels.
- **TelephoneChannel** (`channels/telephone_channel.ex`) - Phoenix Channel handling WebSocket connections from Telephone sidecars.
- **TelephoneSocket** (`channels/telephone_socket.ex`) - Socket handler with JWT authentication.
- **Plugs.Parsers** (`plugs/parsers.ex`) - Custom Plug.Parsers wrapper that reads max body size from runtime config.
- **Plugs.ValidatePath** (`plugs/validate_path.ex`) - Path validation with traversal protection.
- **Plugs.DomainAffinityRouter** (`plugs/domain_affinity_router.ex`) - Domain-based routing plug for custom domain routing.
- **Plugs.WebSocketProxyPlug** (`plugs/websocket_proxy_plug.ex`) - Detects WebSocket upgrade requests and proxies them through Telephone sidecars.
- **Plugs.RateLimiter** (`plugs/rate_limiter.ex`) - Rate limiting plug for protecting endpoints against abuse.
- **WebSocket.ProxyHandler** (`websocket/proxy_handler.ex`) - WebSock handler managing individual proxied WebSocket connections.

### Request Flow

**HTTP Requests:**
```
Client HTTP → ProxyController → ETS lookup → Horde registry → TelephoneChannel → Telephone sidecar → Backend
```

**WebSocket Connections:**
```
Client WS → WebSocketProxyPlug → ETS lookup → Horde registry → ProxyHandler ↔ TelephoneChannel ↔ Telephone → Backend WS
```
Client HTTP → ProxyController → ETS lookup → Horde registry → TelephoneChannel → Telephone sidecar → Backend
```

## Configuration

- **All configuration via environment variables** - never use hardcoded defaults
- **All environment-based config is consolidated in `config/runtime.exs`** for all environments (dev, test, prod)
- Config in `dev.exs` and `test.exs` should only contain environment-specific settings (e.g., debug flags, test database names)
- Required env vars must raise errors if missing in production
- Optional vars use sensible defaults in runtime.exs (e.g., `System.get_env("VAR") || "default"`)

### Key Environment Variables

**Required in Production:**
| Variable | Description |
|----------|-------------|
| `SECRET_KEY_BASE` | Secret key for signing (min 64 chars) |
| `PHX_PORT` | HTTP port |
| `PHX_HOST` | Hostname for URL generation |
| `POSTGRES_USER` | Database username |
| `POSTGRES_PASSWORD` | Database password |
| `POSTGRES_DB` | Database name |
| `POSTGRES_HOST` | Database host |
| `DB_POOL_SIZE` | Connection pool size |
| `DB_QUERY_TIMEOUT` | Max query time (ms) |
| `DB_CONNECT_TIMEOUT` | Max connection time (ms) |
| `SESSION_SIGNING_SALT` | Salt for session cookie signing |
| `LIVE_VIEW_SIGNING_SALT` | Salt for LiveView socket signing |

**Optional (with defaults):**
| Variable | Description | Default |
|----------|-------------|---------|
| `PHX_SERVER` | Start Phoenix server on boot | - |
| `POSTGRES_PORT` | Database port | `5432` |
| `MAX_REQUEST_BODY_SIZE` | Max request body (bytes) | `10485760` (10MB) |
| `MOUNT_STORE_RECONCILE_INTERVAL` | Path reconciliation (ms) | `300000` (5 min) |
| `HOOK_STORE_RECONCILE_INTERVAL` | Hook cache reconciliation (ms) | `300000` (5 min) |
| `TELEPHONE_TOKEN_EXPIRY` | Token expiry (seconds) | `3600` (1 hour) |
| `TELEPHONE_TOKEN_REFRESH_INTERVAL` | Token refresh interval (seconds) | `1800` (30 min) |
| `TELEPHONE_HEARTBEAT_TIMEOUT_MS` | Heartbeat timeout (ms) | `60000` (60 sec) |
| `DNS_CLUSTER_QUERY` | DNS query for clustering | - |
| `ECTO_IPV6` | Enable IPv6 for database | `false` |
| `WEBSOCKET_PROXY_ENABLED` | Enable WebSocket proxying | `true` |
| `WEBSOCKET_CONNECT_TIMEOUT_MS` | WebSocket backend connect timeout | `5000` (5 sec) |
| `WEBSOCKET_MAX_FRAME_SIZE` | Max WebSocket frame size (bytes) | `1048576` (1MB) |
| `WEBSOCKET_IDLE_TIMEOUT_MS` | WebSocket idle timeout | `300000` (5 min) |
| `SESSION_ENCRYPTION_SALT` | Salt for session cookie encryption | - |
| `DATABASE_SSL` | Enable SSL for database connections | `true` (prod) |
| `FORCE_SSL` | Force HTTPS redirect | `true` (prod) |

## LiveView Patterns

- **Always use LiveView streams for collections** - avoids memory issues with large lists
- The `paths_table` component expects a stream (`@streams.paths`) and a boolean (`@paths_empty?`)
- Use `stream(:name, items, reset: true)` when refreshing data (e.g., after create/update/delete)
- Track empty state separately since streams cannot be checked for emptiness

## Testing Guidelines

- Use either `ConnCase` OR `ChannelCase` per file, never both
- Test behavior, not implementation details
- Run `mix test` after each test addition
- Skip implementation-specific tests when architecture changes (tag with `@moduletag :skip`)

## Database Schema

**paths** - Route configuration
- `id` (UUID) - Primary key
- `parent_id` (UUID) - Reference to parent path
- `path` (string) - Path segment (e.g., `api`)
- `full_path` (string) - Complete path from root (e.g., `/call/api`) - auto-computed by trigger
- `mount_point` (boolean) - Whether this path accepts telephone connections
- `request_timeout_ms` (integer) - Max time to wait for telephone response (default: 60000)
- `connect_timeout_ms` (integer) - Max time to wait for telephone connection (default: 5000)
- `deleted_at` (timestamp) - Soft delete support

## Clustering

Uses libcluster with DNS-based discovery in Kubernetes. Horde provides CRDT-based distributed state across nodes.
