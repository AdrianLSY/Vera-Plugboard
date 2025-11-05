# Plugboard

**A dynamic, database-driven reverse proxy built with Phoenix and WebSockets**

[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.7-orange.svg)](https://phoenixframework.org)
[![Tests](https://img.shields.io/badge/tests-685%20passing-success.svg)](test/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Overview

Plugboard is an opinionated reverse proxy that replaces static configuration files with **dynamic, application-driven routing** via persistent WebSocket connections. Applications register themselves through lightweight **"telephone" sidecars**, which establish secure tunnels to Plugboard. This eliminates the need for config files, restarts, or manual port forwarding.

### Highlights

* **Zero-configuration routing** - backends register dynamically at runtime
* **NAT/firewall traversal** - route to hosts behind private networks
* **Database-driven** - all routes managed through UI or API
* **Cluster-ready** - distributed consensus via CRDTs for resilience
* **Auto-scaling aware** - services register/deregister automatically

### Typical Use Cases

* Exposing local servers in development
* Dynamic tenant routing in multi-tenant SaaS
* Auto-scaling environments in the cloud
* Edge or IoT devices behind NAT
* Centralized routing for microservice environments

---

## Architecture

### System Overview

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ HTTP Request: GET /api/users
       ▼
┌───────────────────────────────────┐
│         Plugboard Cluster         │
│  ┌────────────────────────────┐   │
│  │   ProxyController          │   │
│  │   1. Match /api in ETS     │   │
│  │   2. Find telephone in     │   │
│  │      distributed registry  │   │
│  └────────────────────────────┘   │
│               │                   │
│               │ WebSocket Tunnel  │
│               ▼                   │
│  ┌────────────────────────────┐   │
│  │   TelephoneChannel         │   │
│  │   (WebSocket connection)   │   │
│  └────────────────────────────┘   │
└────────┬──────────────────────────┘
         │ Proxy Request over WebSocket
         ▼
┌──────────────────────────────┐
│   Container / Pod            │
│  ┌────────────────────────┐  │
│  │  Telephone (Sidecar)   │  │
│  │  - Maintains WebSocket │  │
│  │  - Intercepts traffic  │  │
│  └────────┬───────────────┘  │
│           │ localhost:PORT   │
│           ▼                  │
│  ┌────────────────────────┐  │
│  │ Your Web Server        │  │
│  │ (Rails, Express,       │  │
│  │  Django, Spring, etc.) │  │
│  └────────────────────────┘  │
└──────────────────────────────┘
```

---

## Technology Stack

* **Phoenix Framework 1.7** - web and WebSocket layer
* **Elixir 1.17** - concurrent and fault-tolerant runtime
* **PostgreSQL 14+** - canonical data store for routes
* **ETS** - in-memory cache for O(1) path lookup
* **Horde** - distributed registry with CRDT-based consistency
* **libcluster** - automatic cluster formation and recovery
* **Phoenix Channels** - bidirectional WebSocket communication
* **Joken** - JWT authentication for sidecar telephones

---

## Design Principles

1. **Terminal Mount Points** - mount paths cannot have children, ensuring deterministic lookups.
2. **CRDT-Based Clustering** - eventual consistency without coordination overhead.
3. **Database as Source of Truth** - ETS and Horde caches are ephemeral and rebuildable.
4. **Request Correlation** - UUID-based tracking for concurrent requests over a single tunnel.
5. **Soft Deletes** - `deleted_at` timestamps preserve historical path data.
6. **Behavioral Testing** - tests validate observable behavior, not internal implementation.

---

## Request Lifecycle

1. Client sends a request to Plugboard (e.g., `GET /api/users`).
2. `ProxyController` performs an O(1) path lookup in ETS.
3. Distributed registry locates the corresponding telephone process.
4. The request is sent over the WebSocket via `TelephoneChannel`.
5. The telephone forwards it to the local backend (e.g., `localhost:3000`).
6. The backend processes the request and responds.
7. The telephone returns the response over the same WebSocket.
8. Plugboard streams the response back to the original client.

---

## Configuration

### Environment Variables

Plugboard uses environment variables for configuration. Copy the `.env` file and customize values for your environment:

```bash
cp .env .env.local  # For local overrides (add to .gitignore)
```

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

## Documentation

* **[AGENTS.md](AGENTS.md)** - internal conventions and Phoenix guidelines
* **[TESTING_GUIDELINES.md](TESTING_GUIDELINES.md)** - testing strategy and patterns
* **[FUTURE_WORK.md](FUTURE_WORK.md)** - roadmap: load balancing, auth, observability, multi-domain routing
* **[CONTRIBUTING.md](CONTRIBUTING.md)** - contribution workflow and standards

---

## License

Licensed under the **MIT License**. See [LICENSE](LICENSE) for details.

---

## Acknowledgments

### Built With

* [Phoenix Framework](https://phoenixframework.org) - by Chris McCord and contributors
* [Horde](https://github.com/derekkraan/horde) - distributed registry by Derek Kraan
* [libcluster](https://github.com/bitwalker/libcluster) - clustering by Paul Schoenfelder

### Inspired By

* [HAProxy](https://www.haproxy.org/) - High-performance load balancing and proxying
* [Nginx](https://nginx.org/) - Reverse proxy and web server architecture
* [Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/) - Zero-trust networking and secure tunneling

### Supported By

* [Rooftop Energy](https://rooftop.my/) - Thanks to the team for allowing me to build out my crazy idea!

---

**Made with Love, Robots & Elixir**
