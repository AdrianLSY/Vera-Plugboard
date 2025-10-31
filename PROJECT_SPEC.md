# Plugboard Agent Development Guide

# Plugboard — Technical Specification & Development Plan

## Overview

Plugboard is a **Phoenix-based reverse proxy** that dynamically connects HTTP traffic to backend web servers through persistent WebSocket connections with lightweight agents. It replaces traditional reverse proxy setups (like Nginx or Traefik) with a dynamic, database-driven routing system.

Agents register **mount points**, which define URI prefixes that Plugboard will proxy. Each mount point is terminal (no sub-paths allowed under it), ensuring clean, deterministic routing.

---

## 1. Core Goals

* Replace static reverse proxies with dynamic, database-managed routes.
* Enable automatic service discovery via connected agents.
* Provide real-time creation/removal of proxies without manual configuration reloads.
* Maintain minimal latency and high throughput.
* Ensure high availability through clustering and in-memory routing tables.

---

## 2. Routing Model

### 2.1 Public URL Pattern

All proxied routes are accessed via:

```
https://plugboard.example.com/proxies/<mount_path>...
```

### 2.2 Routing Logic

1. Incoming requests must start with `/proxies/`. If not, return `404`.
2. Strip `/proxies/` to get `request_path`.
3. Match `request_path` against database table `paths.full_path` where `mount_point = TRUE`.
4. Because mount points are **terminal**, only one match will ever exist.
5. Forwarded path = portion of `request_path` after the matched `full_path`.
6. If no match, return `404`.

### 2.3 Example

| Full Path (mount) | Request Path      | Resulting Forwarded Path |
| ----------------- | ----------------- | ------------------------ |
| `/xyz`            | `/xyz/todo/items` | `/todo/items`            |
| `/abc/todo`       | `/abc/todo/list`  | `/list`                  |

---

## 3. Database Schema

### 3.1 Table: `paths`

```sql
CREATE TABLE paths (
  - `id` BINARY_ID PRIMARY KEY
  user_id BINARY_ID NOT NULL REFERENCES users(id),
  created_by_user_id BINARY_ID NOT NULL REFERENCES users(id),
  parent_id INTEGER REFERENCES paths(id) ON DELETE CASCADE, -- NULL = root
  path TEXT NOT NULL,                -- single path segment (no '/')
  full_path TEXT NOT NULL,           -- canonical absolute path (e.g. '/xyz/todo')
  mount_point BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ NULL
);
CREATE UNIQUE INDEX paths_unique_sibling_path
  ON paths (user_id, parent_id, path)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_paths_full_path ON paths (full_path);
CREATE INDEX idx_paths_mount_point_full_path on paths (mount_point, full_path);
```

### 3.2 Rules

* `parent_id IS NULL` → root path.
* `mount_point = TRUE` → terminal node (no children allowed).
* `full_path` is computed automatically from parent hierarchy.

### 3.3 Triggers

1. **Compute full_path** before insert/update.
2. **Prevent child under a mount:** reject insert if `parent.mount_point = TRUE`.
3. **Prevent marking mount if children exist:** reject update if existing children present.

### 3.4 Soft Delete behavior (deleted_at)

* `deleted_at` is a **soft-delete** flag; records are never physically deleted.
* When a user *creates* a route that matches an existing row where `deleted_at IS NOT NULL`, the system must **restore** that record instead of inserting a duplicate: set `deleted_at = NULL`, set `mount_point = FALSE` (do not automatically enable it), update `updated_at`, and record the action in an audit log.
* This ensures route history and prevents conflicts while avoiding accidental reactivation of mounts.

### 3.5 Ownership & Permissions

* `user_id` and `created_by_user_id` define ownership.
* Ownership cascades down.
* Optional `path_permissions` table can grant limited rights (e.g., can create children).

---

## 4. Agent Model

### 4.1 Lifecycle

* Agents establish an outbound **TLS WebSocket** connection to Plugboard.
* Authenticated via **JWT** (MVP) or **mTLS** (future).
* Upon connection, agent sends a `REGISTER` message with mount points.
* Each mount must exist in DB (`mount_point = TRUE`) and belong to the same user.

### 4.2 Control Protocol

JSON messages over WebSocket:

```json
REGISTER { "agent_id": 1, "user_id": 1, "mounts": ["/xyz/todo"] }
HEARTBEAT { "ts": 1730000000 }
PROXY_REQ { "id": 1, "method": "GET", "forwarded_path": "/items", "headers": {...} }
PROXY_RES { "id": 1, "status": 200, "headers": {...} }
PROXY_ERR { "id": 1, "code": 502, "message": "Agent disconnected" }
```

* Each proxied request/response uses a correlation ID.
* Streaming supported via `REQ_BODY`, `RES_BODY`, `*_END` messages.

### 4.3 Security

* Agents authenticate using signed JWT containing `agent_id`, `user_id`, and allowed `mount_paths`.
* Plugboard validates against DB before accepting registration.

### 4.4 Agent State

* Agents are **ephemeral**.
* Live state stored in memory and replicated cluster-wide.
* Audit history optionally persisted to an `agent_events` table.

---

## 5. Load Balancing

### 5.1 Load Balancing

* Default: **round-robin** among agents registered to same mount.
* Later: least-connections, weighted, or latency-based options.

---

## 6. In-Memory Routing Table

### 6.1 Storage

* On startup, Plugboard loads all mounts into an ETS table `:mounts`.
* Key = `full_path`
* Value = metadata `{id, user_id, updated_at}`

### 6.2 Synchronization

* Source of truth = Postgres.
* After DB changes, application sends `NOTIFY plugboard_mounts, payload`.
* Each node listens and updates ETS atomically.
* Periodic full reload for reconciliation.

### 6.3 Lookup Algorithm

1. Receive request `/proxies/...`.
2. Strip `/proxies/` → get `request_path`.
3. While path not empty:

   * Check ETS for `request_path`.
   * If found, route to agent.
   * Else, remove last path segment and retry.
4. Because mounts are terminal, there’s only one valid match.

### 6.4 Startup

1. Create ETS table.
2. Load all mounts from DB.
3. Subscribe to `NOTIFY`.

---

## 7. Clustering & High Availability

* Erlang cluster across all Plugboard nodes.
* Agents connect to any node.
* State replicated via CRDT or Phoenix.PubSub.
* If a node dies, agents reconnect automatically.
* DB remains authoritative for mount definitions.

---

## 8. Milestones & Deliverables

Each phase below includes tasks, tests, and acceptance criteria. Time estimates are indicative; adapt to team velocity.

### **Phase 1: Core Data Model & Routing (Deliverable: DB + basic API)**

**Objectives**

* Implement `paths` schema and DB triggers.
* Implement full_path computation.
* Implement soft-delete restore behavior (restore existing row set `mount_point=false`).
* Expose an admin API to create/update/soft-delete `paths` (CRUD but soft-delete).

**Tasks**

* Write migrations for `paths`.
* Implement triggers: `compute_full_path`, `prevent_child_under_mount`, `prevent_mount_when_has_children`.
* Implement soft-delete restore logic in the API: on create, if matching full_path with `deleted_at NOT NULL` exists, restore it and set `mount_point=false`.
* Add DB tests for constraints and soft-delete logic.

**Tests / Acceptance**

* Creating a root path and child paths (happy path).
* Trying to create a child under a mount → rejected with 409.
* Trying to mark a node as mount when it has children → rejected with 409.
* Creating a path that matches a soft-deleted row restores it with `mount_point = false`.

### **Phase 2: In-Memory Routing & HTTP Handling (Deliverable: Fast routing & `/proxies/*` endpoint)**

**Objectives**

* Implement ETS-based mount store and synchronization from Postgres.
* Implement Phoenix endpoint to accept `/proxies/*path` and route using ETS.
* Implement DB NOTIFY publisher on path changes and listener to update ETS.

**Tasks**

* ETS table implementation and loader at startup.
* Implement `MountStore.match(request_path)` with normalization and last-segment stripping.
* Add DB NOTIFY publisher hooks in same transaction as path changes.
* Add Phoenix route and controller to strip `/proxies/` and call `MountStore.match/1`.

**Tests / Acceptance**

* Route matching unit tests (various path shapes).
* Integration tests booting app, creating mounts, hitting `/proxies/...` and validating forwarded path.
* Ensure ETS reloads on NOTIFY and routes change without restart.

### **Phase 3: WebSocket Agent System (Deliverable: Agent connectivity & proxying)**

**Objectives**

* Implement performant WS handler for agent connections.
* Implement register/auth handshake with JWT.
* Implement proxy request/response multiplexing over WS.
* Implement basic round-robin LB.

**Tasks**

* Implement Cowboy WS handler and supervision for agent connections.
* Design and implement JSON control frame formats.
* Track agents per mount in in-memory registry (Horde/Registry/DynamicSupervisor pattern).
* Implement `REGISTER` validation against DB (must reference existing mount and user).
* Implement `PROXY_REQ` sending and `PROXY_RES` receiving.

**Tests / Acceptance**

* Simulated agent connects and registers mount.
* Client request to `/proxies/...` proxied to agent; agent returns response; client receives it.
* Multiple agents register same mount → round-robin distribution.
* Invalid registration (wrong user or non-existent mount) rejected.

### **Phase 4: Timeouts & Error Handling (Deliverable: Robust proxy semantics)**

**Objectives**

* Implement timeouts and proper error codes for agent failures.
* Ensure graceful error handling across proxy boundaries.

**Tasks**

* Add timeout handling and translate agent disconnects to `502/504` appropriately.
* Ensure streaming errors are handled correctly and partially-sent responses are surfaced.
* Implement clear error codes and messages for client-facing errors.

**Tests / Acceptance**

* Agent disconnect mid-request returns 502/504 clearly.
* Streaming errors handled and logged.
* Timeouts enforced and surfaced to client.

### **Phase 5: HA & Multi-Node Behavior (Deliverable: Clustered operations)**

**Objectives**

* Ensure multiple Plugboard nodes can operate together.
* If an agent is connected to Node A and a request lands on Node B, Node B can forward request to Node A which then proxies to the agent.

**Tasks**

* Implement cluster-aware agent registry (use Erlang distribution/CRDT/Horde patterns).
* Implement internal RPC for forwarding requests between nodes (GenServer call or internal socket).
* Implement periodic reconciliation job to reload mounts from DB if NOTIFY misses occur.
* Test reconnection and re-registration of agents across nodes.

**Tests / Acceptance**

* Two-node cluster: agent connects to node A; client request to node B is proxied correctly to agent on A.
* Node crash: agent reconnects to other node and resumes serving traffic.
* Reconcilation recovers missed NOTIFY updates.

### **Phase 6: Hardening & Documentation (Deliverable: Production-ready)**

**Objectives**

* Stabilize codebase and prepare for production deployment.
* Provide clear runbooks and migration notes.

**Tasks**

* Add comprehensive tests and load testing scenarios.
* Review and harden triggers and transaction boundaries.
* Prepare migration scripts and rollout plan.
* Draft runbooks: scaling, certificate rotation, agent provisioning, and troubleshooting.

**Tests / Acceptance**

* Soak test for 24 hours with simulated agents and traffic.
* Migration dry-run successful on staging DB.
* Runbooks reviewed and validated.

---

## 9. Acceptance Criteria (MVP)

* ✅ Routes `/proxies/<mount_path>` correctly forward to registered agent.
* ✅ Mount points are terminal (no children allowed).
* ✅ Agents register only for existing mount points.
* ✅ Round-robin load balancing functional.
* ✅ DB and ETS stay synchronized on updates.
* ✅ Cluster nodes route traffic consistently after restart.

---

## 10. Future Work (Post-MVP)

* mTLS agent authentication.
* Sticky sessions and weighted load balancing.
* Advanced observability (Prometheus, tracing, metrics).
* Admin dashboard for mount management.
* Automatic scaling of agent pools.
* WebSocket upgrade proxying.

---
