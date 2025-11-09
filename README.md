# Plugboard

**WebSocket-based reverse proxy server for the Vera-Stack**

[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](../LICENSE)
[![CI](https://github.com/AdrianLSY/Vera-Plugboard/actions/workflows/ci.yml/badge.svg)](https://github.com/AdrianLSY/Vera-Plugboard/actions/workflows/ci.yml)
[![codecov](https://codecov.io/gh/AdrianLSY/Vera-Plugboard/branch/main/graph/badge.svg)](https://codecov.io/gh/AdrianLSY/Vera-Plugboard)

---

## Overview

Plugboard is a reverse proxy server that routes HTTP requests through WebSocket tunnels to Telephone sidecars. It maintains a distributed registry of active connections and uses in-memory caching for O(1) path matching.

### Key Features

- **WebSocket Tunnels** - Persistent connections to Telephone sidecars
- **O(1) Path Matching** - ETS-backed route lookup with terminal mount strategy
- **Distributed Registry** - CRDT-based clustering via Horde
- **Request Correlation** - UUID-based concurrent request handling
- **Automatic Failover** - Cluster-wide rebalancing and partition healing
- **Phoenix Channels** - Full Phoenix framework integration

---

## Quick Start

### Prerequisites

- Elixir 1.17+
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
PHX_SERVER=true
PHX_PORT=4000
PHX_HOST=localhost

# PostgreSQL Database
POSTGRES_USER=plugboard
POSTGRES_PASSWORD=plugboard
POSTGRES_DB=plugboard
POSTGRES_HOST=localhost
POSTGRES_PORT=6432

# Application Settings
MAX_REQUEST_BODY_SIZE=10485760
TELEPHONE_TOKEN_EXPIRY=3600
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

### Test

```bash
# Register a mount point
curl -X POST http://localhost:4000/api/mounts \
  -H "Content-Type: application/json" \
  -d '{"path": "/api", "telephone_id": "service-a", "backend_port": 3000}'

# Make a request through the proxy
curl http://localhost:4000/call/api/
```

---

## How It Works

```
┌──────────────┐
│    Client    │
└──────┬───────┘
       │ HTTP Request: GET /call/api/users
       ▼
┌─────────────────────────────────────┐
│       Plugboard (:4000)             │
│  • ETS Path Lookup (O(1))           │
│  • Horde Registry Lookup            │
│  • Request Correlation (UUID)       │
└────────────┬────────────────────────┘
             │ WebSocket (Phoenix Channel)
             ▼
┌─────────────────────────────────────┐
│      Telephone Sidecar              │
│  • Receives proxy_req               │
│  • Forwards to backend              │
│  • Returns proxy_res                │
└─────────────────────────────────────┘
             │
             ▼
┌─────────────────────────────────────┐
│   Backend Service (:3000)           │
└─────────────────────────────────────┘
```

---

## Architecture

### Core Components

**ProxyController**
- Entry point for incoming HTTP requests
- Performs ETS path lookup (O(1))
- Delegates to TelephoneChannel via Horde registry
- Streams responses back to clients

**TelephoneChannel**
- Manages WebSocket connections from Telephone sidecars
- Handles bidirectional Phoenix Channel protocol
- Implements request correlation with UUIDs
- Manages connection lifecycle and reconnection

**MountStore**
- PostgreSQL-backed route configuration storage
- Enforces terminal mount point constraint
- Provides soft-delete functionality
- Synchronizes ETS cache on changes

**Horde Registry**
- CRDT-based distributed process registry
- Automatic failover and rebalancing
- Cluster-wide service discovery
- Consistent hashing for load distribution

### Terminal Mount Strategy

Plugboard uses a **terminal mount point** strategy to avoid routing ambiguity:

```elixir
# Valid configuration
/api          -> Service A
/api/v2       -> Service B

# Invalid configuration (conflict)
/api          -> Service A
/api/users    -> Service B  # Rejected: /api is already terminal
```

Routes are stored in ETS with normalized paths (trailing slashes removed). Only terminal routes (those without children) can handle requests. Longest matching prefix wins.

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

**mount_points table**

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `path` | String | Mount path (e.g., `/api`) |
| `telephone_id` | String | Identifier for Telephone sidecar |
| `backend_port` | Integer | Port on backend service |
| `metadata` | JSONB | Additional configuration |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |
| `deleted_at` | Timestamp | Soft delete timestamp |

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
| `PHX_SERVER`                                   | Start Phoenix server on boot          | `true`                                | ✅       |
| `PHX_PORT`                                     | HTTP port                             | `4000`                                | ✅       |
| `PHX_HOST`                                     | Hostname for URL generation           | `localhost`                           | ✅       |
| `POSTGRES_USER`                                | Database username                     | `plugboard`                           | ✅       |
| `POSTGRES_PASSWORD`                            | Database password                     | `plugboard`                           | ✅       |
| `POSTGRES_DB`                                  | Database name                         | `plugboard`                           | ✅       |
| `POSTGRES_HOST`                                | Database host                         | `localhost`                           | ✅       |
| `POSTGRES_PORT`                                | Database port                         | `6432`                                | ✅       |
| `DB_POOL_SIZE`                                 | Connection pool size                  | `10`                                  | ✅       |
| `DB_QUERY_TIMEOUT`                             | Max query time (ms)                   | `15000`                               | ✅       |
| `DB_CONNECT_TIMEOUT`                           | Max connection time (ms)              | `5000`                                | ✅       |
| `MAX_REQUEST_BODY_SIZE`                        | Max request body (bytes)              | `10485760` (10MB)                     | ✅       |
| `MOUNT_STORE_RECONCILE_INTERVAL`               | Path reconciliation interval (ms)     | `30000` (30s)                         | ✅       |
| `TELEPHONE_TOKEN_EXPIRY`                       | Token expiry time (seconds)           | `3600` (1 hour)                       | ✅       |
| `TELEPHONE_TOKEN_REFRESH_INTERVAL`             | Token refresh interval (seconds)      | `1800` (30 min)                       | ✅       |
| `DNS_CLUSTER_QUERY`                            | DNS query for clustering              | `plugboard.default.svc.cluster.local` | ❌       |
| `ECTO_IPV6`                                    | Enable IPv6 for database              | `false`                               | ❌       |

---

## API Reference

### Mount Point Management

**Create Mount Point**

```http
POST /api/mounts
Content-Type: application/json

{
  "path": "/api",
  "telephone_id": "service-a",
  "backend_port": 3000,
  "metadata": {}
}
```

**List Mount Points**

```http
GET /api/mounts
```

**Delete Mount Point**

```http
DELETE /api/mounts/:id
```

### Health Check

```http
GET /health
```

Returns `200 OK` if server is healthy.

---

## Features

### Routing & Path Matching
- O(1) ETS-backed path lookup
- Terminal mount point strategy (no ambiguous routes)
- Longest prefix matching
- Automatic path normalization

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
│   │   ├── telephone_channel.ex  # WebSocket channel handler
│   │   └── proxy_controller.ex   # HTTP request handler
│   └── plugboard_web/
│       ├── channels/             # Phoenix channels
│       ├── controllers/          # API controllers
│       └── router.ex             # Route definitions
├── priv/repo/migrations/         # Database migrations
├── test/                         # Test suite
├── config/                       # Configuration files
└── mix.exs                       # Project dependencies
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

### Testing Strategy

- **Behavioral Testing** - Focus on observable behavior
- **Contract Testing** - Validate interfaces and protocols
- **Integration Tests** - Critical paths and end-to-end flows
- **Mocked Dependencies** - Database and external services when appropriate

See [TESTING_GUIDELINES.md](TESTING_GUIDELINES.md) for detailed patterns.

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
- **[TESTING_GUIDELINES.md](TESTING_GUIDELINES.md)** - Testing strategy and patterns
- **[FUTURE_WORK.md](FUTURE_WORK.md)** - Roadmap and planned features
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution workflow

---

## License

Licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

---

## Related Projects

- **[Vera Telephone](https://github.com/AdrianLSY/Vera-Telephone)** - The WebSocket sidecar component
- **[Vera Reverse Proxy](https://github.com/AdrianLSY/Vera-Reverse-Proxy)** - The complete technology stack

---
