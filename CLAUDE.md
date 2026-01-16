# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Important: Read AGENTS.md First

**Always read `AGENTS.md` before making changes.** It is the development reference/bible containing Phoenix 1.8 conventions, Elixir guidelines, LiveView patterns, authentication handling, and UI/UX standards for this project.

## Project Overview

Plugboard is a WebSocket-based reverse proxy server for the Vera-Stack. It routes HTTP requests through WebSocket tunnels to Telephone sidecars using:
- ETS-backed O(1) path matching with terminal mount strategy
- CRDT-based distributed registry via Horde
- Phoenix Channels for WebSocket communication
- UUID-based request correlation for concurrent request handling

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

### Web Layer (lib/plugboard_web/)

- **ProxyController** (`controllers/proxy_controller.ex`) - Entry point for proxied HTTP requests. Routes `/call/*path` through WebSocket tunnels.
- **TelephoneChannel** (`channels/telephone_channel.ex`) - Phoenix Channel handling WebSocket connections from Telephone sidecars.
- **TelephoneSocket** (`channels/telephone_socket.ex`) - Socket handler with JWT authentication.

### Request Flow

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

| Variable | Description | Default |
|----------|-------------|---------|
| `MAX_REQUEST_BODY_SIZE` | Max request body (bytes) | `10485760` (10MB) |
| `MOUNT_STORE_RECONCILE_INTERVAL` | Path reconciliation (ms) | `300000` (5 min) |
| `TELEPHONE_TOKEN_EXPIRY` | Token expiry (seconds) | `3600` (1 hour) |
| `TELEPHONE_HEARTBEAT_TIMEOUT_MS` | Heartbeat timeout (ms) | `60000` (60 sec) |

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

**mount_points** - Route configuration
- `path` (string) - Mount path (e.g., `/api`)
- `telephone_id` (string) - Identifier for Telephone sidecar
- `backend_port` (integer) - Port on backend service
- `deleted_at` (timestamp) - Soft delete support

## Clustering

Uses libcluster with DNS-based discovery in Kubernetes. Horde provides CRDT-based distributed state across nodes.
