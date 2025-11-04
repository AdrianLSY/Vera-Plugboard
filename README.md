# Plugboard

**A dynamic, database-driven reverse proxy powered by Phoenix and WebSockets**

[![Elixir](https://img.shields.io/badge/elixir-1.17-purple.svg)](https://elixir-lang.org)
[![Phoenix](https://img.shields.io/badge/phoenix-1.7-orange.svg)](https://phoenixframework.org)
[![Tests](https://img.shields.io/badge/tests-685%20passing-success.svg)](test/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

---

## Overview

Plugboard is an opionated reverse proxy that replaces traditional static configuration files with dynamic, application-driven routing through persistent WebSocket connections. Applications connect to Plugboard via standalone "telephone" applications that run as sidecars in the same container as your web server. The telephone intercepts traffic between Plugboard and your application, establishing the WebSocket tunnel. no config files, no restarts, no port forwarding, no headaches.

**Key Benefits:**
- ✅ **Zero-configuration routing** - Backends register themselves dynamically
- ✅ **NAT/Firewall traversal** - Route to servers behind firewalls without port forwarding
- ✅ **Database-driven** - Manage routes through UI or API
- ✅ **High availability** - Distributed, clustered architecture with CRDT-based consensus
- ✅ **Auto-scaling friendly** - Services appear/disappear automatically as they scale

**Common Use Cases:**
- Development environments (expose local servers easily)
- Multi-tenant SaaS (dynamic customer routing)
- Auto-scaling cloud deployments (automatic service discovery)
- Edge computing/IoT (route to devices behind NAT)
- Microservices routing (centralized gateway without service mesh)

---

## Architecture

### How It Works

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
│  │  Django, Spring, etc.) |  │
│  └────────────────────────┘  │
└──────────────────────────────┘
```

### Technology Stack

- **Phoenix Framework 1.7** - Web framework with WebSocket support
- **Elixir 1.17** - Concurrent, fault-tolerant runtime
- **PostgreSQL 14+** - Source of truth for paths and configuration
- **ETS** - In-memory O(1) path lookup cache
- **Horde** - Distributed process registry with CRDT-based consensus
- **libcluster** - Automatic cluster formation and healing
- **Phoenix Channels** - WebSocket communication layer
- **Joken** - JWT authentication for telephones

### Key Design Principles

1. **Terminal Mount Points** - Paths marked as mount points cannot have children, ensuring deterministic routing
2. **CRDT-Based Clustering** - Horde provides eventual consistency without coordination overhead
3. **PostgreSQL as Source of Truth** - All persistent state in the database; ETS and Horde are rebuildable caches
4. **Request Correlation** - UUID-based request tracking enables concurrent requests over single WebSocket
5. **Soft Deletes** - Paths preserve history with `deleted_at` timestamps for audit and restoration
6. **Behavior-Focused Testing** - Tests verify observable behavior, not implementation details

### Request Flow

1. **Client** sends HTTP request to Plugboard (e.g., `GET /api/users`)
2. **ProxyController** performs O(1) lookup in ETS MountStore to find matching path (`/api`)
3. **DistributedRegistry** locates telephone process (may be on remote cluster node)
4. **TelephoneChannel** forwards request over WebSocket tunnel with correlation UUID
5. **Telephone (Sidecar)** receives request and forwards to local web server (e.g., `http://localhost:3000`)
6. **Web Server** processes request and returns response to telephone
7. **Telephone** forwards response back through WebSocket to Plugboard
8. **ProxyController** streams response back to original client

---

## Documentation

- **[AGENTS.md](AGENTS.md)** - Development guidelines and Phoenix best practices (Mostly there just to throw to an LLM Agent)
- **[TESTING_GUIDELINES.md](TESTING_GUIDELINES.md)** - Testing philosophy and patterns
- **[FUTURE_WORK.md](FUTURE_WORK.md)** - Planned enhancements (load balancing, auth, observability, Caddy multi-domain support)
- **[CONTRIBUTING.md](CONTRIBUTING.md)** - Contribution guidelines and workflow

---

## Contributing

[Soon.]

---

## License

This project is licensed under the **MIT License** - see the [LICENSE](LICENSE) file for details.

---

## Acknowledgments

**Built With:**
- [Phoenix Framework](https://phoenixframework.org) by Chris McCord and contributors
- [Horde](https://github.com/derekkraan/horde) by Derek Kraan - Distributed process registry
- [libcluster](https://github.com/bitwalker/libcluster) by Paul Schoenfelder - Cluster formation

**Inspired By:**
- [HAProxy](https://www.haproxy.org/) - High-performance load balancing and proxying
- [Nginx](https://nginx.org/) - Reverse proxy and web server architecture
- [Cloudflare Tunnel](https://www.cloudflare.com/products/tunnel/) - Zero-trust networking and secure tunneling


**Supported By:**
- [Rooftop Energy](https://rooftop.my/) - Thanks to the team for allowing me to build out my crazy idea!

**Made with ❤️ and Elixir**
