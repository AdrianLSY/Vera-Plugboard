# Plugboard

**The dynamic reverse proxy component of Vera-Stack**

[![Tests](https://img.shields.io/badge/tests-685%20passing-success.svg)](test/)

---

## Overview

Plugboard is the reverse proxy server component that handles incoming HTTP requests and routes them through WebSocket tunnels to registered Telephone sidecars. It maintains a distributed registry of active connections and uses in-memory caching for high-performance path matching.

**Key Responsibilities:**
* Accept incoming HTTP requests from clients
* Perform O(1) path lookup for route matching
* Maintain WebSocket connections with Telephone sidecars
* Proxy requests through tunnels to backend services
* Manage route registration and persistence
* Provide cluster-wide service discovery

---

## Architecture

### Core Components

#### ProxyController
* Entry point for all incoming HTTP requests
* Performs path matching against registered mount points
* Delegates requests to the appropriate Telephone connection
* Streams responses back to clients

#### TelephoneChannel
* Manages WebSocket connections from Telephone sidecars
* Handles bidirectional communication for proxied requests
* Implements request correlation with UUIDs
* Manages connection lifecycle and reconnection

#### MountStore
* Database-backed storage for route configurations
* Enforces terminal mount point constraint
* Provides soft-delete functionality
* Synchronizes state across cluster nodes

#### Distributed Registry (Horde)
* CRDT-based process registry for Telephone connections
* Automatic failover and rebalancing
* Cluster-wide service discovery
* Consistent hashing for load distribution

### Data Flow

```
Client Request
      ↓
ProxyController
      ↓
ETS Path Lookup (O(1))
      ↓
Horde Registry Lookup
      ↓
TelephoneChannel (WebSocket)
      ↓
Telephone Sidecar
      ↓
Backend Service
```

---

## Internal Architecture

### Path Matching Algorithm

Plugboard uses a **terminal mount point** strategy:

1. Routes are stored in ETS with normalized paths (trailing slashes removed)
2. Incoming requests are matched using prefix matching
3. Only terminal routes (those without children) can handle requests
4. Longest matching prefix wins

**Example:**

```elixir
# Valid configuration
/api          -> Service A
/api/v2       -> Service B

# Invalid configuration (conflict)
/api          -> Service A
/api/users    -> Service B  # Cannot have both - /api is terminal
```

### Request Correlation

Each proxied request receives a unique correlation ID:

```elixir
%{
  correlation_id: UUID.uuid4(),
  method: "GET",
  path: "/api/users",
  headers: [...],
  body: <<...>>
}
```

This allows multiple concurrent requests over a single WebSocket connection.

### Database Schema

#### mount_points table

| Column | Type | Description |
|--------|------|-------------|
| `id` | UUID | Primary key |
| `path` | String | Mount path (e.g., `/api`) |
| `telephone_id` | String | Identifier for the Telephone sidecar |
| `backend_port` | Integer | Port on the backend service |
| `metadata` | JSONB | Additional configuration |
| `inserted_at` | Timestamp | Creation time |
| `updated_at` | Timestamp | Last modification |
| `deleted_at` | Timestamp | Soft delete timestamp |

### Clustering

Plugboard uses **libcluster** for automatic cluster formation:

* DNS-based discovery in Kubernetes
* Gossip protocol for membership
* Automatic partition healing
* CRDT-based state synchronization via Horde

**Configuration:**

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

---

## Development

### Prerequisites

* Elixir 1.17+
* Erlang/OTP 26+
* PostgreSQL 14+

### Setup

```bash
# Install dependencies
mix deps.get

# Setup database
mix ecto.setup

# Run migrations
mix ecto.migrate

# Start the server
mix phx.server

# Run tests
mix test

# Run with coverage
mix test --cover
```

### Running Locally

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

### Testing Strategy

Plugboard follows a **behavioral testing** approach:

* Tests validate observable behavior, not implementation details
* Focus on contract testing for interfaces
* Use integration tests for critical paths
* Mock external dependencies (database in some cases)

See [TESTING_GUIDELINES.md](TESTING_GUIDELINES.md) for detailed testing patterns.

---

## Configuration

Plugboard uses environment variables for configuration. Copy the `.env` file and customize values for your environment:

```bash
cp .env .env.local  # For local overrides (add to .gitignore)
```

### Environment Variables

#### Phoenix Server

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `SECRET_KEY_BASE` | Secret key for signing cookies/sessions (min 64 chars). Generate with `mix phx.gen.secret` | - | ✅ |
| `PHX_SERVER` | Start Phoenix server on boot | `true` | ✅ |
| `PHX_PORT` | HTTP port for the server | `4000` | ✅ |
| `PHX_HOST` | Hostname for URL generation | `localhost` | ✅ |

#### PostgreSQL Database

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `POSTGRES_USER` | Database username | `plugboard` | ✅ |
| `POSTGRES_PASSWORD` | Database password | `plugboard` | ✅ |
| `POSTGRES_DB` | Database name | `plugboard` | ✅ |
| `POSTGRES_HOST` | Database host (localhost or container name) | `localhost` | ✅ |
| `POSTGRES_PORT` | Database port | `6432` | ✅ |
| `DB_POOL_SIZE` | Connection pool size | `10` | ✅ |
| `DB_QUERY_TIMEOUT` | Max query time in milliseconds | `15000` | ✅ |
| `DB_CONNECT_TIMEOUT` | Max connection time in milliseconds | `5000` | ✅ |
| `ECTO_IPV6` | Enable IPv6 for database | `false` | ❌ |

#### Application Settings

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `MAX_REQUEST_BODY_SIZE` | Max request body size in bytes | `10485760` (10MB) | ✅ |
| `MOUNT_STORE_RECONCILE_INTERVAL` | Path reconciliation interval (ms) | `30000` (30s) | ✅ |

#### Telephone (Sidecar) Tokens

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `TELEPHONE_TOKEN_EXPIRY` | Token expiry time in seconds | `3600` (1 hour) | ✅ |
| `TELEPHONE_TOKEN_REFRESH_INTERVAL` | Token refresh interval in seconds | `1800` (30 min) | ✅ |

#### Testing

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `MIX_TEST_PARTITION` | Test partition for CI parallel execution | - | ❌ |

#### Production Only

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `DNS_CLUSTER_QUERY` | DNS query for cluster discovery (e.g., `plugboard.default.svc.cluster.local`) | - | ❌ |

### Example .env Template

```bash
# =============================================================================
# PLUGBOARD ENVIRONMENT CONFIGURATION
# =============================================================================

# Phoenix Server
SECRET_KEY_BASE=your_secret_key_here_min_64_chars
PHX_SERVER=true
PHX_PORT=4000
PHX_HOST=localhost

# PostgreSQL Database
POSTGRES_USER=plugboard
POSTGRES_PASSWORD=plugboard
POSTGRES_DB=plugboard
POSTGRES_HOST=localhost
POSTGRES_PORT=6432
DB_POOL_SIZE=10
DB_QUERY_TIMEOUT=15000
DB_CONNECT_TIMEOUT=5000
ECTO_IPV6=false

# Testing
MIX_TEST_PARTITION=

# Application Settings
MAX_REQUEST_BODY_SIZE=10485760
MOUNT_STORE_RECONCILE_INTERVAL=30000

# Telephone Token Configuration
TELEPHONE_TOKEN_EXPIRY=3600
TELEPHONE_TOKEN_REFRESH_INTERVAL=1800

# Production Clustering
DNS_CLUSTER_QUERY=
```

---

## API Reference

### Mount Point Management

#### Create Mount Point

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

#### List Mount Points

```http
GET /api/mounts
```

#### Delete Mount Point

```http
DELETE /api/mounts/:id
```

---

## Monitoring & Observability

### Health Checks

```http
GET /health
```

Returns `200 OK` if the server is healthy.

### Metrics (Planned)

* Request latency histograms
* Active WebSocket connections
* Route hit rates
* Error rates by status code

---

## Deployment

### Docker

```dockerfile
FROM hexpm/elixir:1.17.0-erlang-26.0.0-alpine-3.18.0 AS build

WORKDIR /app

# Install dependencies
RUN mix local.hex --force && \
    mix local.rebar --force

COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

# Build release
COPY lib lib
COPY priv priv
RUN mix compile
RUN mix release

# Runtime image
FROM alpine:3.18

RUN apk add --no-cache openssl ncurses-libs

WORKDIR /app

COPY --from=build /app/_build/prod/rel/plugboard ./

CMD ["bin/plugboard", "start"]
```

### Kubernetes

See [deployment/kubernetes](deployment/kubernetes) for Helm charts and manifests.

---

## Documentation

* **[AGENTS.md](AGENTS.md)** - Development conventions and Phoenix guidelines
* **[TESTING_GUIDELINES.md](TESTING_GUIDELINES.md)** - Testing strategy and patterns
* **[FUTURE_WORK.md](FUTURE_WORK.md)** - Roadmap and planned features
* **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution workflow and standards

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines on:
* Code style and conventions
* Submitting pull requests
* Running the test suite
* Reporting bugs

---

## Troubleshooting

### Common Issues

#### Connection Refused

```
** (Postgrex.Error) connection not available and request was dropped from queue
```

**Solution:** Ensure PostgreSQL is running and accessible:

```bash
psql -h localhost -p 6432 -U plugboard -d plugboard
```

#### Port Already in Use

```
** (EXIT) an exception was raised: ** (RuntimeError) PORT 4000 already in use
```

**Solution:** Change the port or kill the existing process:

```bash
PHX_PORT=4001 mix phx.server
```

#### WebSocket Connection Failures

Check that:
1. Telephone has a valid JWT token
2. Network allows WebSocket connections
3. Firewall rules permit traffic on PHX_PORT

---

## License

Licensed under the **MIT License**. See [../LICENSE](../LICENSE) for details.
