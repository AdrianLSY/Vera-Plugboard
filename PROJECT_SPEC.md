# Plugboard Telephone Development Guide

# Plugboard — Technical Specification & Development Plan

## Overview

Plugboard is a **Phoenix-based reverse proxy** that dynamically connects HTTP traffic to backend web servers through persistent WebSocket connections with lightweight telephones. It replaces traditional reverse proxy setups (like Nginx or Traefik) with a dynamic, database-driven routing system.

Telephones register **mount points**, which define URI prefixes that Plugboard will proxy. Each mount point is terminal (no sub-paths allowed under it), ensuring clean, deterministic routing.

---

## 1. Core Goals

* Replace static reverse proxies with dynamic, database-managed routes.
* Enable automatic service discovery via connected telephones.
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
  id BINARY_ID PRIMARY KEY,
  parent_id BINARY_ID REFERENCES paths(id) ON DELETE RESTRICT, -- NULL = root
  path TEXT NOT NULL,                -- single path segment (no '/')
  full_path TEXT NOT NULL,           -- canonical absolute path (e.g. '/xyz/todo')
  mount_point BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  deleted_at TIMESTAMPTZ NULL
);
CREATE UNIQUE INDEX paths_unique_sibling_path
  ON paths (COALESCE(parent_id::text, ''), path)
  WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX paths_unique_full_path
  ON paths (full_path)
  WHERE deleted_at IS NULL;
CREATE INDEX idx_paths_full_path ON paths (full_path);
CREATE INDEX idx_paths_mount_point_full_path on paths (mount_point, full_path);
CREATE INDEX idx_paths_parent_id ON paths (parent_id);
```

### 3.2 Table: `user_paths`

Junction table for many-to-many relationship between users and paths with role-based access control.

```sql
CREATE TABLE user_paths (
  id BINARY_ID PRIMARY KEY,
  user_id BINARY_ID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  path_id BINARY_ID NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
  role TEXT NOT NULL CHECK (role IN ('owner', 'maintainer', 'viewer')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX user_paths_unique_user_path
  ON user_paths (user_id, path_id);
CREATE INDEX idx_user_paths_user_id ON user_paths (user_id);
CREATE INDEX idx_user_paths_path_id ON user_paths (path_id);
CREATE INDEX idx_user_paths_role ON user_paths (role);
```

### 3.3 Table: `telephone_tokens`

Stores JWT tokens for telephone authentication. Each token belongs to exactly one path.

```sql
CREATE TABLE telephone_tokens (
  id BINARY_ID PRIMARY KEY,
  path_id BINARY_ID NOT NULL REFERENCES paths(id) ON DELETE CASCADE,
  user_id BINARY_ID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  token_hash TEXT NOT NULL,           -- SHA256 hash of JWT for revocation lookups
  description TEXT,                   -- User-provided description (e.g., "Production server")
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

**Token Management:**
* `token_hash` stores SHA256 hash of JWT for revocation checks (not the JWT itself)
* `expires_at` set based on `TELEPHONE_TOKEN_EXPIRY` config
* `revoked_at IS NULL` means token is active
* `last_used_at` updated on each successful connection for auditing

### 3.4 Path Timeout Configuration

Timeout fields added to `paths` table for telephone request handling:

```sql
ALTER TABLE paths
ADD COLUMN request_timeout_ms INTEGER DEFAULT 60000 NOT NULL,
ADD COLUMN connect_timeout_ms INTEGER DEFAULT 5000 NOT NULL;
```

* `request_timeout_ms` - Maximum time (ms) to wait for telephone response (default: 60000ms = 60s)
* `connect_timeout_ms` - Maximum time (ms) to wait for telephone connection (default: 5000ms = 5s)
* Allows per-path SLA configuration for different service requirements

### 3.5 Rules

* `parent_id IS NULL` → root path.
* `mount_point = TRUE` → terminal node (no children allowed).
* `full_path` is computed automatically from parent hierarchy.
* `full_path` must be globally unique (enforced by unique index).
* Paths are global entities; user access controlled via `user_paths` junction table.
* Telephone tokens belong to exactly one path (1:1 relationship).

### 3.6 Triggers

1. **Compute full_path** before insert/update.
2. **Prevent child under a mount:** reject insert if `parent.mount_point = TRUE`.
3. **Prevent marking mount if children exist:** reject update if existing children present.
4. **Update descendant full_paths:** cascade full_path updates when parent path changes.

### 3.7 Soft Delete behavior (deleted_at)

* `deleted_at` is a **soft-delete** flag; records are never physically deleted.
* When a user *creates* a route that matches an existing row where `deleted_at IS NOT NULL`, the system must **restore** that record instead of inserting a duplicate: set `deleted_at = NULL`, set `mount_point = FALSE` (do not automatically enable it), update `updated_at`.
* When restoring, create or reuse the `user_path` association with `owner` role.
* This ensures route history and prevents conflicts while avoiding accidental reactivation of mounts.

### 3.8 Ownership & Permissions

User access to paths is managed through the `user_paths` junction table with three role levels:

* **owner**: Full control over the path and descendants (create, read, update, delete, manage users)
* **maintainer**: Can modify path but cannot delete or manage users
* **viewer**: Read-only access

When creating a path, a `user_path` association is automatically created with `role = 'owner'`.

Permissions cascade down the hierarchy - users with access to a parent path can be granted access to its children independently.

---

## 4. Telephone Model

### 4.1 Lifecycle

* Telephones establish an outbound **TLS WebSocket** connection to Plugboard via `/telephone`.
* Authenticated via **JWT** (MVP) or **mTLS** (future).
* Upon successful JWT authentication, telephone is registered to its authorized path.
* Each token belongs to a specific path (stored in `telephone_tokens` table).

### 4.2 Token Management

**Token Creation:**
* Tokens can be created by:
  1. Users with `owner` or `maintainer` role on a path (via UI or API)
  2. API endpoint for programmatic token generation
* Each token belongs to exactly one path (1:1 relationship)
* Token contains JWT with claims: `{token_id, path_id, user_id, exp, iat}`

**Token Lifecycle:**
* Short-lived tokens with configurable expiry (env: `TELEPHONE_TOKEN_EXPIRY`, default: 3600s)
* Auto-refresh at configurable intervals (env: `TELEPHONE_TOKEN_REFRESH_INTERVAL`, default: 1800s)
* Refresh handled via `REFRESH_TOKEN` message over established WebSocket
* Tokens stored in `telephone_tokens` table with revocation support

### 4.3 Control Protocol

JSON messages over WebSocket:

```json
REGISTER { "token": "jwt_string" }
REGISTER_ACK { "status": "ok", "path": "/xyz/todo", "expires_in": 3600 }
REGISTER_ERROR { "status": "error", "reason": "Invalid token" }

HEARTBEAT { "ts": 1730000000 }
HEARTBEAT_ACK { "ts": 1730000000 }

REFRESH_TOKEN {}
REFRESH_TOKEN_ACK { "token": "new_jwt_string", "expires_in": 3600 }

PROXY_REQ { "method": "GET", "path": "/items", "headers": {...}, "body": "..." }
PROXY_RES { "status": 200, "headers": {...}, "body": "..." }
PROXY_ERR { "code": 502, "message": "Backend error" }
```

**Note:** No correlation IDs - one request at a time per telephone connection (simple synchronous model for MVP).

### 4.4 Security

* Telephones authenticate using JWT from `telephone_tokens` table.
* JWT validation checks:
  1. Signature valid (using app secret key base)
  2. Token not expired
  3. Token not revoked (`revoked_at IS NULL` in DB)
  4. Path exists with `mount_point = TRUE` and `deleted_at IS NULL`
  5. Token's `path_id` references valid mount point

### 4.5 Telephone State

* Telephones are **ephemeral** - no persistent state beyond token.
* Live connections tracked in `TelephoneRegistry` (ETS-backed).
* Connection state: `{telephone_pid, path_id, connected_at}`
* Audit history optionally persisted to `telephone_events` table (future).

### 4.6 Request Timeout Configuration

* Each path stores timeout configuration in database:
  - `request_timeout_ms` - Maximum time to wait for telephone response (default: 60000ms)
  - `connect_timeout_ms` - Maximum time to wait for telephone connection (default: 5000ms)
* Timeouts are per-path to allow different SLAs for different services.
* On timeout: return `504 Gateway Timeout` to client.

---

## 5. Load Balancing

### 5.1 Load Balancing

* Default: **round-robin** among telephones registered to same mount.
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
   * If found, route to telephone.
   * Else, remove last path segment and retry.
4. Because mounts are terminal, there’s only one valid match.

### 6.4 Startup

1. Create ETS table.
2. Load all mounts from DB.
3. Subscribe to `NOTIFY`.

---

## 7. Clustering & High Availability

* Erlang cluster across all Plugboard nodes.
* Telephones connect to any node.
* State replicated via CRDT or Phoenix.PubSub.
* If a node dies, telephones reconnect automatically.
* DB remains authoritative for mount definitions.

---

## 8. Milestones & Deliverables

Each phase below includes tasks, tests, and acceptance criteria. Time estimates are indicative; adapt to team velocity.

### **Phase 1: Core Data Model & Routing (Deliverable: DB + basic API)** ✅ **COMPLETE**

**Completion Date:** October 31, 2024 (Updated: November 1, 2024)

**Objectives**

* ✅ Implement `paths` schema and DB triggers.
* ✅ Implement `user_paths` junction table for role-based access control.
* ✅ Implement full_path computation.
* ✅ Implement soft-delete restore behavior (restore existing row set `mount_point=false`).
* ✅ Expose an admin API to create/update/soft-delete `paths` (CRUD but soft-delete).
* ✅ Implement user-path association management API.

**Tasks**

* ✅ Write migrations for `paths` and `user_paths`.
* ✅ Implement triggers: `compute_full_path`, `prevent_child_under_mount`, `prevent_mount_when_has_children`, `update_descendant_full_paths`.
* ✅ Implement soft-delete restore logic in the API: on create, if matching full_path with `deleted_at NOT NULL` exists, restore it and set `mount_point=false`.
* ✅ Implement automatic owner association when creating paths.
* ✅ Add DB tests for constraints, soft-delete logic, and concurrent operations.
* ✅ Implement user-path association API (add, update role, remove, list, check permissions).

**Tests / Acceptance**

* ✅ Creating a root path and child paths (happy path).
* ✅ Trying to create a child under a mount → rejected with database error.
* ✅ Trying to mark a node as mount when it has children → rejected with database error.
* ✅ Creating a path that matches a soft-deleted row restores it with `mount_point = false`.
* ✅ User-path associations created automatically with owner role.
* ✅ Multiple users can access same path with different roles.
* ✅ User isolation enforced via junction table queries.
* ✅ All 238 tests passing including concurrent operation tests.

**See:** `PHASE_1_COMPLETE.md` for detailed documentation.

### **Phase 2: In-Memory Routing & HTTP Handling (Deliverable: Fast routing & `/proxies/*` endpoint)** ✅ **COMPLETE**

**Completion Date:** November 2, 2024

**Objectives**

* ✅ Implement ETS-based mount store and synchronization from Postgres.
* ✅ Implement Phoenix endpoint to accept `/proxies/*path` and route using ETS.
* ✅ Implement DB NOTIFY publisher on path changes and listener to update ETS.

**Tasks**

* ✅ ETS table implementation and loader at startup.
* ✅ Implement `MountStore.match(request_path)` with normalization and last-segment stripping.
* ✅ Add DB NOTIFY publisher hooks via database triggers (atomic with path changes).
* ✅ Add Phoenix route and controller to strip `/proxies/` and call `MountStore.match/1`.
* ✅ Add path validation plug for security (path traversal, null bytes, depth/length limits).
* ✅ Add database timeout configuration for all environments.
* ✅ Create comprehensive MountNotifier test suite.

**Tests / Acceptance**

* ✅ Route matching unit tests (various path shapes).
* ✅ Integration tests booting app, creating mounts, hitting `/proxies/...` and validating forwarded path.
* ✅ ETS reloads on NOTIFY and routes change without restart.
* ✅ Security validation tests (path traversal, encoding attacks, DoS prevention).
* ✅ MountNotifier resilience tests (malformed payloads, connection recovery).
* ✅ All 423 tests passing (18 new MountNotifier tests added).

**See:** `PHASE_2_QA_FIXES.md` for implementation details and QA review responses.

### **Phase 3: WebSocket Telephone System (Deliverable: Telephone connectivity & proxying)**

**Objectives**

* Implement `telephone_tokens` table and JWT token management.
* Add timeout configuration fields to `paths` table.
* Implement Phoenix Channel handler for telephone WebSocket connections at `/telephone`.
* Implement JWT authentication and validation for telephone connections.
* Implement basic synchronous request/response proxying (no streaming).
* Implement round-robin load balancing for multiple telephones on same path.
* Configure token expiry and refresh via environment variables.

**Tasks**

* Create migration for `telephone_tokens` table with path_id, user_id, token_hash, expires_at, revoked_at.
* Create migration to add `request_timeout_ms` and `connect_timeout_ms` to `paths` table.
* Implement `TelephoneToken` schema and context functions (generate, validate, revoke, refresh).
* Add JWT config to `runtime.exs` (TELEPHONE_TOKEN_EXPIRY, TELEPHONE_TOKEN_REFRESH_INTERVAL).
* Implement `TelephoneSocket` at `/telephone` with JWT authentication in `connect/3`.
* Implement `TelephoneChannel` with message handlers: `REGISTER`, `HEARTBEAT`, `PROXY_REQ`, `PROXY_RES`, `REFRESH_TOKEN`.
* Create `TelephoneRegistry` GenServer with ETS backing to track connected telephones per path.
* Update `ProxyController` to look up telephone via registry and forward requests with Task.async.
* Implement round-robin selection when multiple telephones registered to same path.
* Add telemetry events for telephone connections, disconnections, and proxy requests.
* Token creation API endpoint (POST /api/paths/:path_id/tokens) with owner/maintainer role check.

**Tests / Acceptance**

* Token creation requires owner or maintainer role on path.
* Token validation checks signature, expiry, revocation status, and path mount point.
* Telephone connects with valid JWT and registers successfully.
* Telephone with invalid/expired/revoked JWT is rejected.
* HTTP request to `/proxies/...` forwarded to registered telephone via WebSocket.
* Telephone response relayed back to HTTP client correctly.
* Multiple telephones on same path receive requests in round-robin order.
* Request timeout returns 504 Gateway Timeout when telephone doesn't respond in time.
* No telephone available for path returns 503 Service Unavailable.
* Token refresh updates expiry and returns new JWT.
* All tests passing with Phase 3 additions.

### **Phase 4: Timeouts & Error Handling (Deliverable: Robust proxy semantics)**

**Objectives**

* Implement timeouts and proper error codes for agent failures.
* Ensure graceful error handling across proxy boundaries.

**Tasks**

* Add timeout handling and translate telephone disconnects to `502/504` appropriately.
* Ensure streaming errors are handled correctly and partially-sent responses are surfaced.
* Implement clear error codes and messages for client-facing errors.

**Tests / Acceptance**

* Telephone disconnect mid-request returns 502/504 clearly.
* Streaming errors handled and logged.
* Timeouts enforced and surfaced to client.

### **Phase 5: HA & Multi-Node Behavior (Deliverable: Clustered operations)**

**Objectives**

* Ensure multiple Plugboard nodes can operate together.
* If a telephone is connected to Node A and a request lands on Node B, Node B can forward request to Node A which then proxies to the telephone.

**Tasks**

* Implement cluster-aware telephone registry (use Erlang distribution/CRDT/Horde patterns).
* Implement internal RPC for forwarding requests between nodes (GenServer call or internal socket).
* Implement periodic reconciliation job to reload mounts from DB if NOTIFY misses occur.
* Test reconnection and re-registration of telephones across nodes.

**Tests / Acceptance**

* Two-node cluster: telephone connects to node A; client request to node B is proxied correctly to telephone on A.
* Node crash: telephone reconnects to other node and resumes serving traffic.
* Reconcilation recovers missed NOTIFY updates.

### **Phase 6: Hardening & Documentation (Deliverable: Production-ready)**

**Objectives**

* Stabilize codebase and prepare for production deployment.
* Provide clear runbooks and migration notes.

**Tasks**

* Add comprehensive tests and load testing scenarios.
* Review and harden triggers and transaction boundaries.
* Prepare migration scripts and rollout plan.
* Draft runbooks: scaling, certificate rotation, telephone provisioning, and troubleshooting.

**Tests / Acceptance**

* Soak test for 24 hours with simulated telephones and traffic.
* Migration dry-run successful on staging DB.
* Runbooks reviewed and validated.

---

## 9. Acceptance Criteria (MVP)

**Phase 1 (Complete):**
* ✅ Path hierarchy with parent-child relationships implemented
* ✅ Mount points are terminal (no children allowed) - enforced by database triggers
* ✅ Telephones register only for existing mount points that they have access to via user_paths
* ✅ User-path associations with role-based access control (owner, maintainer, viewer)
* ✅ Soft-delete with automatic restoration logic
* ✅ All database constraints enforced at DB level
* ✅ Comprehensive test coverage (238 tests passing)

**Phase 2 (Complete):**
* ✅ Routes `/proxies/<mount_path>` match against ETS-based mount store
* ✅ Fast O(1) path matching with segment stripping fallback
* ✅ DB and ETS stay synchronized via PostgreSQL NOTIFY triggers
* ✅ MountStore with periodic reconciliation (5 minute fallback)
* ✅ Comprehensive security validation (path traversal, null bytes, depth limits)
* ✅ Database timeout configuration (15s queries, 5s connections)
* ✅ Full test coverage including MountNotifier (423 tests passing)

**Phase 3-6 (Pending):**
* ⏳ WebSocket telephone connectivity and registration
* ⏳ Proxy requests forwarded to registered telephones
* ⏳ Round-robin load balancing functional
* ⏳ Cluster nodes route traffic consistently after restart

---

## 10. Future Work (Post-MVP)

* mTLS telephone authentication.
* Sticky sessions and weighted load balancing.
* Advanced observability (Prometheus, tracing, metrics).
* Admin dashboard for mount management.
* Automatic scaling of telephone pools.
* WebSocket upgrade proxying.

---
