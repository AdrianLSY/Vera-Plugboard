# Future Work & Enhancements

This document outlines planned features, enhancements, and research areas for Plugboard beyond the MVP release.

**Last Updated:** November 4, 2025  
**Status:** Planned Enhancements

---

## Table of Contents

1. [Load Balancing Strategies](#1-load-balancing-strategies)
2. [Authentication & Security](#2-authentication--security)
3. [Advanced Routing](#3-advanced-routing)
4. [Observability & Operations](#4-observability--operations)
5. [Performance Optimizations](#5-performance-optimizations)
6. [Protocol Support](#6-protocol-support)
7. [Developer Experience](#7-developer-experience)
8. [Multi-Tenancy & Isolation](#8-multi-tenancy--isolation)
9. [Caddy Integration](#9-caddy-integration)

---

## 1. Load Balancing Strategies

### 1.1 Current Implementation

**Status:** ✅ Implemented (Phase 3)

Plugboard currently implements **round-robin load balancing** using a simple timestamp-based algorithm:

```elixir
# lib/plugboard/distributed_registry.ex:213
index = rem(System.system_time(:microsecond), length(telephones))
{pid, _value} = Enum.at(telephones, index)
```

**Characteristics:**
- Simple and predictable
- No state tracking required
- Works well for homogeneous backends
- Distributes load evenly across telephones

**Limitations:**
- Doesn't account for backend capacity differences
- Ignores current backend load
- No awareness of request latency
- Treats all telephones equally regardless of resources

---

### 1.2 Least Connections

**Complexity:** Medium  

**Description:**  
Route requests to the telephone with the fewest active connections. This strategy adapts to backend capacity and handles slow requests better than round-robin.

**Implementation Approach:**

```elixir
# Store active connection count in registry metadata
def register(path_id, _pid \\ nil, value \\ nil) do
  value = Map.merge(value || %{}, %{
    path_id: path_id,
    registered_at: System.system_time(),
    active_connections: 0  # NEW
  })
  # ... existing registration logic
end

# Track connections in ProxyController
def forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
  increment_connection_count(telephone_pid)
  
  try do
    # ... existing proxy logic
  after
    decrement_connection_count(telephone_pid)
  end
end

# Selection algorithm
def get_telephone_least_connections(path_id) do
  case lookup(path_id) do
    [] -> {:error, :no_telephone}
    telephones ->
      {pid, _value} = Enum.min_by(telephones, fn {_pid, meta} ->
        Map.get(meta, :active_connections, 0)
      end)
      {:ok, pid}
  end
end
```

**Benefits:**
- Better handling of slow backends
- Automatic load distribution based on capacity
- Prevents overwhelming slow telephones
- Works well with heterogeneous backends

**Challenges:**
- Requires connection tracking
- State must be kept synchronized across cluster
- Need cleanup on telephone disconnect
- Horde CRDT update latency

**Telemetry:**
```elixir
:telemetry.execute(
  [:plugboard, :load_balancer, :connection_count],
  %{count: active_connections},
  %{path_id: path_id, telephone_pid: pid, strategy: :least_connections}
)
```

---

### 1.3 Weighted Round-Robin

**Complexity:** Low  

**Description:**  
Assign weights to telephones based on their capacity (CPU, memory, or configured weight). Telephones with higher weights receive proportionally more requests.

**Use Cases:**
- Heterogeneous hardware (some servers have more CPU/RAM)
- Canary deployments (send 5% traffic to new version)
- Geographic preferences (prefer local backends)

**Implementation Approach:**

```elixir
# Store weight in telephone metadata
def register(path_id, _pid \\ nil, opts \\ %{}) do
  weight = Map.get(opts, :weight, 100)  # Default weight: 100
  
  value = %{
    path_id: path_id,
    registered_at: System.system_time(),
    weight: weight  # NEW
  }
  # ... registration logic
end

# Weighted selection algorithm (Weighted Random Selection)
def get_telephone_weighted(path_id) do
  case lookup(path_id) do
    [] -> {:error, :no_telephone}
    telephones ->
      total_weight = Enum.sum(Enum.map(telephones, fn {_pid, meta} -> 
        Map.get(meta, :weight, 100) 
      end))
      
      random = :rand.uniform(total_weight)
      select_by_weight(telephones, random, 0)
  end
end

defp select_by_weight([{pid, meta} | _rest], random, acc) when acc + meta.weight >= random do
  {:ok, pid}
end

defp select_by_weight([{_pid, meta} | rest], random, acc) do
  select_by_weight(rest, random, acc + meta.weight)
end
```

**Configuration Example:**

```elixir
# Telephone connection with weight
socket = connect_telephone(token, weight: 200)  # 2x normal capacity

# Canary deployment
socket_prod = connect_telephone(token_prod, weight: 95)   # 95% traffic
socket_canary = connect_telephone(token_canary, weight: 5)  # 5% traffic
```

**Benefits:**
- Simple to implement
- Flexible capacity management
- Supports canary deployments
- Predictable distribution

---

### 1.4 Latency-Based / Response Time

**Complexity:** HIGH  

**Description:**  
Route requests to telephones with the lowest average response time. This automatically adapts to network latency and backend processing speed.

**Implementation Approach:**

```elixir
# Track response time in ETS or Horde metadata
defmodule Plugboard.LatencyTracker do
  use GenServer
  
  # Moving average of last N requests
  def record_latency(telephone_pid, latency_ms) do
    GenServer.cast(__MODULE__, {:record, telephone_pid, latency_ms})
  end
  
  def get_average_latency(telephone_pid) do
    GenServer.call(__MODULE__, {:get_avg, telephone_pid})
  end
  
  # Keep sliding window of last 100 requests
  def handle_cast({:record, pid, latency}, state) do
    window = Map.get(state, pid, [])
    new_window = [latency | Enum.take(window, 99)]  # Keep last 100
    {:noreply, Map.put(state, pid, new_window)}
  end
end

# Selection algorithm
def get_telephone_lowest_latency(path_id) do
  case lookup(path_id) do
    [] -> {:error, :no_telephone}
    telephones ->
      {pid, _value} = Enum.min_by(telephones, fn {pid, _meta} ->
        LatencyTracker.get_average_latency(pid)
      end)
      {:ok, pid}
  end
end

# Update ProxyController to track latency
def forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
  start_time = System.monotonic_time()
  
  result = # ... existing proxy logic
  
  duration = System.monotonic_time() - start_time
  duration_ms = System.convert_time_unit(duration, :native, :millisecond)
  LatencyTracker.record_latency(telephone_pid, duration_ms)
  
  result
end
```

**Benefits:**
- Automatically adapts to network conditions
- Detects slow backends
- Geographic optimization (prefers nearby telephones)
- No manual configuration needed

**Challenges:**
- Cold start problem (new telephones have no history)
- Oscillation risk (fast backend gets overloaded, becomes slow)
- Need decay/timeout for stale data
- Clustering complexity (sync latency data?)

**Research Needed:**
- Optimal window size for moving average
- Decay function for old measurements
- Outlier handling (network blips)
- Integration with circuit breaker pattern

---

### 1.5 Consistent Hashing (Sticky Sessions)

**Complexity:** MEDIUM  

**Description:**  
Route requests from the same client/session to the same backend telephone. Useful for stateful backends that maintain session state.

**Use Cases:**
- Stateful backends (session data in memory)
- WebSocket upgrade proxying
- File upload continuation
- Shopping cart persistence

**Implementation Approach:**

```elixir
# Hash based on session ID, user ID, or IP address
def get_telephone_consistent(path_id, session_key) do
  case lookup(path_id) do
    [] -> {:error, :no_telephone}
    telephones ->
      # Consistent hash ring
      hash = :erlang.phash2(session_key)
      index = rem(hash, length(telephones))
      {pid, _value} = Enum.at(telephones, index)
      {:ok, pid}
  end
end

# Usage in ProxyController
def proxy(conn, params) do
  session_key = get_session_key(conn)  # Could be: session ID, user ID, client IP
  
  case TelephoneRegistry.get_telephone(path_id, strategy: :consistent, key: session_key) do
    {:ok, telephone_pid} -> # ... proxy request
  end
end
```

**Challenges:**
- Need session identifier extraction
- Telephone removal causes rehashing
- Not all requests have stable identifiers
- May create uneven load distribution

**Alternative:** Use round-robin and require backends to share session state (Redis, DB).

---

### 1.6 Geographic / Multi-Region

**Complexity:** VERY HIGH  

**Description:**  
Route requests to telephones in the same geographic region as the client. Reduces latency for globally distributed backends.

**Implementation Approach:**

```elixir
# Store region in telephone metadata
def register(path_id, _pid \\ nil, opts \\ %{}) do
  region = Map.get(opts, :region, "us-east-1")
  
  value = %{
    path_id: path_id,
    registered_at: System.system_time(),
    region: region,  # NEW
    node: node()
  }
  # ... registration logic
end

# Selection by region
def get_telephone_by_region(path_id, preferred_region) do
  case lookup(path_id) do
    [] -> {:error, :no_telephone}
    telephones ->
      # Try to find telephone in same region
      case Enum.find(telephones, fn {_pid, meta} -> 
        Map.get(meta, :region) == preferred_region 
      end) do
        {pid, _meta} -> {:ok, pid}
        nil -> get_telephone(path_id)  # Fallback to round-robin
      end
  end
end

# Determine client region from request
def proxy(conn, params) do
  client_region = determine_client_region(conn)  # GeoIP or CloudFront header
  
  case TelephoneRegistry.get_telephone(path_id, strategy: :geographic, region: client_region) do
    {:ok, telephone_pid} -> # ... proxy request
  end
end
```

**Requirements:**
- GeoIP database or CDN header parsing
- Telephone region configuration
- Fallback strategy when no regional telephone available
- Multi-region Horde cluster setup

---

### 1.7 Load Balancing Strategy Configuration

**Complexity:** MEDIUM  

**Description:**  
Make load balancing strategy configurable per path, allowing different strategies for different services.

**Database Schema Change:**

```sql
-- Add to paths table
ALTER TABLE paths
ADD COLUMN load_balancing_strategy TEXT DEFAULT 'round_robin' NOT NULL,
ADD COLUMN load_balancing_config JSONB DEFAULT '{}' NOT NULL;

-- Valid strategies: 'round_robin', 'least_connections', 'weighted', 'latency_based', 'consistent_hash'
```

**Configuration Examples:**

```elixir
# Round-robin (default)
%{
  load_balancing_strategy: "round_robin",
  load_balancing_config: %{}
}

# Weighted round-robin
%{
  load_balancing_strategy: "weighted",
  load_balancing_config: %{
    "default_weight" => 100
  }
}

# Least connections
%{
  load_balancing_strategy: "least_connections",
  load_balancing_config: %{
    "connection_threshold" => 1000  # Alert if over 1000 connections
  }
}

# Latency-based
%{
  load_balancing_strategy: "latency_based",
  load_balancing_config: %{
    "window_size" => 100,  # Last 100 requests
    "decay_seconds" => 300  # Forget measurements after 5 minutes
  }
}

# Consistent hash (sticky sessions)
%{
  load_balancing_strategy: "consistent_hash",
  load_balancing_config: %{
    "hash_key" => "session_id"  # Options: session_id, user_id, client_ip
  }
}
```

**Implementation:**

```elixir
# lib/plugboard/telephone_registry.ex
def get_telephone(path_id) do
  path = Paths.get_path(path_id)
  strategy = path.load_balancing_strategy || "round_robin"
  config = path.load_balancing_config || %{}
  
  case strategy do
    "round_robin" -> get_telephone_round_robin(path_id)
    "least_connections" -> get_telephone_least_connections(path_id)
    "weighted" -> get_telephone_weighted(path_id, config)
    "latency_based" -> get_telephone_lowest_latency(path_id, config)
    "consistent_hash" -> get_telephone_consistent(path_id, config)
    _ -> {:error, :unknown_strategy}
  end
end
```

**UI Support:**  
Add load balancing strategy selector to path management UI with strategy-specific configuration options.

---

### 1.8 Health Checks & Circuit Breaker

**Complexity:** HIGH  

**Description:**  
Automatically detect unhealthy telephones and remove them from rotation. Implement circuit breaker pattern to prevent cascading failures.

**Health Check Types:**

1. **Active Health Checks:** Periodic ping/health endpoint
2. **Passive Health Checks:** Monitor error rate and timeouts
3. **Circuit Breaker:** Automatically trip after N consecutive failures

**Implementation Approach:**

```elixir
defmodule Plugboard.HealthChecker do
  use GenServer
  
  # Configuration
  @check_interval 30_000  # 30 seconds
  @failure_threshold 3     # Mark unhealthy after 3 failures
  @success_threshold 2     # Mark healthy after 2 successes
  
  # Health states: :healthy, :unhealthy, :circuit_open
  
  def init(_) do
    schedule_check()
    {:ok, %{}}
  end
  
  def handle_info(:check_health, state) do
    # Get all registered telephones
    active_paths = DistributedRegistry.list_active_paths()
    
    Enum.each(active_paths, fn path_id ->
      telephones = DistributedRegistry.lookup(path_id)
      
      Enum.each(telephones, fn {pid, _meta} ->
        check_telephone_health(pid)
      end)
    end)
    
    schedule_check()
    {:noreply, state}
  end
  
  defp check_telephone_health(pid) do
    # Send PING, expect PONG within 5 seconds
    send(pid, {:health_check, self()})
    
    receive do
      {:pong, ^pid} -> 
        mark_healthy(pid)
      after 5000 ->
        mark_unhealthy(pid)
    end
  end
end

# Circuit breaker in ProxyController
def forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
  case CircuitBreaker.get_state(telephone_pid) do
    :open ->
      # Circuit is open, don't send request
      HTTPError.send_error(conn, 503, 
        reason: "Circuit breaker open for this telephone",
        details: %{telephone_pid: inspect(telephone_pid)}
      )
    
    :half_open ->
      # Try request, update circuit breaker based on result
      case try_request(telephone_pid, ...) do
        {:ok, response} -> 
          CircuitBreaker.record_success(telephone_pid)
          response
        {:error, _} ->
          CircuitBreaker.record_failure(telephone_pid)
          # Try next telephone
      end
    
    :closed ->
      # Normal operation
      # ... existing proxy logic
  end
end
```

**Benefits:**
- Automatic failure detection
- Prevents requests to unhealthy backends
- Graceful degradation
- Self-healing (automatic retry after cooldown)

**Telemetry:**
```elixir
:telemetry.execute(
  [:plugboard, :health_check, :state_change],
  %{count: 1},
  %{telephone_pid: pid, from: :healthy, to: :unhealthy, failures: 3}
)
```

---

## 2. Authentication & Security

### 2.1 mTLS Telephone Authentication

**Complexity:** HIGH  

**Description:**  
Support mutual TLS (mTLS) authentication for telephones in addition to JWT tokens. Provides stronger security for production deployments.

**Benefits:**
- Stronger authentication (certificate-based)
- No token rotation needed
- Better for highly secure environments
- Supports client certificates from PKI

**Implementation Approach:**

```elixir
# config/runtime.exs
config :plugboard, PlugboardWeb.Endpoint,
  https: [
    port: 4001,
    cipher_suite: :strong,
    certfile: "priv/cert/server.crt",
    keyfile: "priv/cert/server.key",
    cacertfile: "priv/cert/ca.crt",
    verify: :verify_peer,  # Require client certificate
    fail_if_no_peer_cert: false  # Allow JWT fallback
  ]

# lib/plugboard_web/channels/telephone_socket.ex
def connect(params, socket, connect_info) do
  case authenticate(params, connect_info) do
    {:ok, :mtls, path_id, user_id} ->
      # Authenticated via mTLS
      {:ok, assign(socket, path_id: path_id, user_id: user_id, auth_type: :mtls)}
    
    {:ok, :jwt, path_id, user_id} ->
      # Authenticated via JWT (existing)
      {:ok, assign(socket, path_id: path_id, user_id: user_id, auth_type: :jwt)}
    
    {:error, reason} ->
      :error
  end
end

defp authenticate(params, connect_info) do
  # Try mTLS first
  case extract_client_cert(connect_info) do
    {:ok, cert} -> validate_certificate(cert)
    _ -> validate_jwt(params["token"])  # Fallback to JWT
  end
end
```

**Requirements:**
- Certificate authority (CA) setup
- Client certificate generation tooling
- Certificate revocation list (CRL) or OCSP
- Documentation for certificate management

---

### 2.2 IP Whitelisting / Allowlisting

**Complexity:** LOW  

**Description:**  
Restrict telephone connections to specific IP ranges. Useful for enterprise deployments.

**Database Schema:**

```sql
ALTER TABLE paths
ADD COLUMN allowed_ip_ranges TEXT[] DEFAULT '{}';

-- Example: ['10.0.0.0/8', '192.168.1.0/24']
```

**Implementation:**

```elixir
def connect(params, socket, connect_info) do
  client_ip = get_client_ip(connect_info)
  
  case validate_ip_allowlist(client_ip, path.allowed_ip_ranges) do
    :ok -> # ... proceed with authentication
    {:error, :ip_not_allowed} -> :error
  end
end
```

---

### 2.3 API Rate Limiting (Per User / Path)

**Complexity:** MEDIUM  

**Description:**  
Implement per-user and per-path rate limiting to prevent abuse and ensure fair usage.

**Current State:**  
Global request body size limit is configured via `MAX_REQUEST_BODY_SIZE` environment variable (default 10MB).

**Planned Implementation:**

```elixir
# Using PlugAttack or custom rate limiter
defmodule PlugboardWeb.RateLimiter do
  use PlugAttack
  
  # Rate limit: 100 requests per minute per user
  rule "by_user", conn do
    if user_id = conn.assigns[:current_user]&.id do
      throttle(user_id, 
        limit: 100, 
        period: 60_000, 
        storage: {PlugAttack.Storage.Ets, PlugboardWeb.RateLimiter.Storage}
      )
    else
      :ok
    end
  end
  
  # Rate limit: 1000 requests per minute per path
  rule "by_path", conn do
    if path_id = conn.assigns[:path_id] do
      throttle("path:#{path_id}", 
        limit: 1000, 
        period: 60_000
      )
    else
      :ok
    end
  end
end
```

---

### 2.4 Per-Path Request Body Size Limits

**Complexity:** LOW  

**Description:**  
Allow configuring maximum request body size on a per-path basis, overriding the global default set in `MAX_REQUEST_BODY_SIZE`.

**Current State:**  
Global limit configured via environment variable applies to all paths.

**Proposed Schema:**

```sql
ALTER TABLE paths
ADD COLUMN max_body_size_bytes INTEGER;
-- NULL means use global default from MAX_REQUEST_BODY_SIZE
```

**Implementation:**

```elixir
# In ProxyController, check path-specific limit before forwarding
def proxy(conn, params) do
  path = get_path_from_registry(params)
  max_size = path.max_body_size_bytes || Application.get_env(:plugboard, :max_request_body_length)
  
  # Validate content-length header against limit
  case Plug.Conn.get_req_header(conn, "content-length") do
    [size_str] ->
      size = String.to_integer(size_str)
      if size > max_size do
        send_resp(conn, 413, "Request body too large")
      else
        forward_to_telephone(conn, path)
      end
    _ ->
      forward_to_telephone(conn, path)
  end
end
```

**Use Cases:**
- **File upload services:** Allow larger bodies (100MB+) for file upload paths
- **API endpoints:** Keep smaller limits (1-5MB) for typical JSON APIs
- **Webhook receivers:** Configure based on webhook provider limits
- **Media services:** Allow very large uploads for video/audio processing

**Benefits:**
- Fine-grained control over resource usage per service
- Prevent individual services from consuming excessive memory
- Better multi-tenant isolation

---

## 3. Advanced Routing

### 3.1 Request Header-Based Routing

**Complexity:** MEDIUM  

**Description:**  
Route requests based on HTTP headers (e.g., API version, user agent, feature flags).

**Use Cases:**
- A/B testing (route based on experiment header)
- API versioning (route v1 vs v2 based on header)
- Mobile vs web routing
- Canary deployments

**Example Configuration:**

```json
{
  "routing_rules": [
    {
      "header": "X-API-Version",
      "value": "v2",
      "telephone_tag": "api-v2"
    },
    {
      "header": "X-Feature-Flag",
      "value": "new-ui",
      "telephone_tag": "canary"
    }
  ]
}
```

---

### 3.2 Path Rewriting

**Complexity:** LOW  

**Description:**  
Rewrite request paths before forwarding to telephone. Useful for legacy API compatibility.

**Example:**

```elixir
# Request: /api/v1/users
# Rewrite to: /users
# Forward to telephone

config = %{
  "path_rewrites" => [
    %{"match" => ~r/^\/api\/v1/, "replace" => ""}
  ]
}
```

---

## 4. Observability & Operations

### 4.1 Prometheus Metrics Export

**Complexity:** LOW  

**Description:**  
Export metrics in Prometheus format for monitoring and alerting.

**Planned Metrics:**

```
# Counters
plugboard_proxy_requests_total{path_id, method, status}
plugboard_telephone_connections_total{path_id, result}
plugboard_errors_total{type, path_id}

# Gauges
plugboard_active_telephones{path_id}
plugboard_active_connections{path_id, telephone_id}
plugboard_mount_points_total

# Histograms
plugboard_request_duration_seconds{path_id, method}
plugboard_telephone_response_time_seconds{path_id}
```

**Implementation:**

```elixir
# Use TelemetryMetricsPrometheus
{:telemetry_metrics_prometheus, "~> 1.0"}

# config/runtime.exs
config :plugboard, PlugboardWeb.Telemetry,
  metrics_port: 9568  # Prometheus scrape endpoint
```

**Status:** Planned for Phase 7 ✅

---

### 4.2 Distributed Tracing (OpenTelemetry)

**Complexity:** MEDIUM  

**Description:**  
Implement distributed tracing to track requests across Plugboard → Telephone → Backend.

**Trace Spans:**

```
HTTP Request (ProxyController)
  ├─ Mount Lookup (MountStore)
  ├─ Telephone Selection (DistributedRegistry)
  ├─ WebSocket Send (TelephoneChannel)
  └─ Backend Processing (Telephone → Backend)
      └─ Database Query (Backend)
```

**Implementation:**

```elixir
# Use OpentelemetryPhoenix + OpentelemetryEcto
{:opentelemetry_phoenix, "~> 1.0"}
{:opentelemetry_ecto, "~> 1.0"}

# Propagate trace context through WebSocket
def handle_in("proxy_res", %{"request_id" => request_id, "trace_context" => ctx}, socket) do
  OpenTelemetry.Ctx.attach(ctx)
  # ... handle response
end
```

**Benefits:**
- End-to-end request visibility
- Performance bottleneck identification
- Error correlation across services
- Latency analysis

---

### 4.3 Real-Time Monitoring Dashboard

**Complexity:** MEDIUM  

**Description:**  
Build a real-time dashboard showing active telephones, request rates, and system health.

**Features:**
- Live telephone status (connected, disconnected, unhealthy)
- Request rate graphs per path
- Error rate monitoring
- Cluster topology visualization
- Active connection count

**Technology Options:**
- Phoenix LiveView (native Elixir)
- Grafana (Prometheus + dashboards)
- Custom React dashboard (WebSocket data feed)

---

## 5. Performance Optimizations

### 5.1 Request Body Streaming

**Complexity:** HIGH  

**Description:**  
Stream large request bodies (file uploads, video uploads, data imports) to telephones instead of buffering entire body in memory. This enables support for large file transfers and real-time data streaming scenarios.

**Current State:**  
Plugboard currently has a configurable request body size limit (default 10MB, set via `MAX_REQUEST_BODY_SIZE` in `.env`). Requests are buffered entirely in memory before being forwarded. This works well for typical API requests but is inefficient for large file uploads.

**Current Limitation:**

```elixir
# lib/plugboard_web/controllers/proxy_controller.ex:157
{:ok, body, conn} = Plug.Conn.read_body(conn)  # Buffers entire body in memory!
# Current limit: configurable via MAX_REQUEST_BODY_SIZE (default 10MB)
```

**Proposed Implementation:**

```elixir
# Stream body chunks to telephone
def forward_request_to_telephone(conn, telephone_pid, path, forwarded_path) do
  # Send initial metadata
  send(telephone_pid, {:proxy_request_start, request_id, metadata})
  
  # Stream body chunks
  Plug.Conn.read_body(conn, [read_length: 8192, read_timeout: 5000])
  |> Stream.unfold(fn
    {:ok, chunk, conn} -> 
      send(telephone_pid, {:proxy_request_chunk, request_id, chunk})
      Plug.Conn.read_body(conn, [read_length: 8192])
    {:done, conn} ->
      send(telephone_pid, {:proxy_request_end, request_id})
      nil
  end)
  |> Stream.run()
end
```

**Benefits:**
- Support large file uploads (GB+) beyond current memory-based limits
- Reduced memory usage and improved scalability
- Lower latency (start processing before entire upload completes)
- Enable real-time streaming scenarios (video uploads, live data feeds)
- Remove the need for artificially low size limits

**Use Cases:**
- **File Uploads:** Large file uploads (images, videos, documents, backups)
- **Video Streaming:** Live video uploads or surveillance feeds
- **Data Imports:** CSV/JSON bulk data imports
- **Backup & Restore:** Database backups, system snapshots
- **Media Processing:** Audio/video transcoding pipelines
- **Real-time Analytics:** Streaming log aggregation and processing

**Challenges:**
- Maintain request correlation during chunked streaming
- Handle backpressure when telephone/backend is slower than upload
- Error recovery and partial upload handling
- Progress tracking and resumable uploads
- Concurrent stream management per WebSocket connection

---

### 5.2 Response Body Streaming

**Complexity:** HIGH  

**Description:**  
Stream large response bodies (file downloads, data exports, video streaming) from telephones to clients instead of buffering entire response in memory. This complements request body streaming and enables bidirectional streaming scenarios.

**Current Limitation:**

```elixir
# Responses are currently buffered before being sent to client
# Need to implement chunked transfer encoding support
```

**Proposed Implementation:**

```elixir
# Stream response chunks from telephone to client
def handle_info({:proxy_response_chunk, request_id, chunk}, socket) do
  # Forward chunk to waiting client connection
  send_chunk(conn, chunk)
  {:noreply, socket}
end

def handle_info({:proxy_response_end, request_id}, socket) do
  # Finalize chunked response
  send_chunk(conn, "")
  {:noreply, socket}
end
```

**Benefits:**
- Support large file downloads (GB+) without memory exhaustion
- Real-time data streaming to clients
- Lower latency (start sending response before backend completes)
- Reduced server memory footprint

**Use Cases:**
- **File Downloads:** Large file downloads (videos, backups, exports)
- **Data Exports:** CSV/JSON/XML exports of large datasets
- **Video Streaming:** Live video streaming or VOD delivery
- **Log Streaming:** Real-time log tailing and streaming
- **Report Generation:** Large PDF/Excel report generation
- **Database Dumps:** Streaming database exports

**Challenges:**
- Coordinate streaming between WebSocket and HTTP connection
- Handle client disconnections during streaming
- Implement proper backpressure mechanisms
- Support range requests for partial content (HTTP 206)
- Error handling mid-stream

---

### 5.3 HTTP/2 Support

**Complexity:** MEDIUM  

**Description:**  
Support HTTP/2 for client connections (already supported by Bandit adapter).

**Benefits:**
- Multiplexing (multiple requests on single connection)
- Header compression
- Server push (if needed)

**Status:** Bandit supports HTTP/2, may require minimal configuration.

---

### 5.4 Connection Pooling for Telephones

**Complexity:** MEDIUM  

**Description:**  
Allow multiple WebSocket connections per backend service for higher throughput.

**Current Model:** 1 telephone = 1 WebSocket connection per backend instance

**Proposed Model:** 1 telephone = N WebSocket connections (pool)

**Benefits:**
- Higher concurrent request handling
- Better utilization of multi-core backends

---

## 6. Protocol Support

### 6.1 WebSocket Upgrade Proxying

**Complexity:** VERY HIGH  

**Description:**  
Allow clients to establish WebSocket connections through Plugboard to backend services.

**Challenges:**
- Need to proxy WebSocket upgrade handshake
- Bidirectional message forwarding
- Connection lifecycle management
- Multiple concurrent WebSocket connections

**Use Case:**  
Client WebSocket → Plugboard → Telephone → Backend WebSocket

---

### 6.2 gRPC Support

**Complexity:** HIGH  

**Description:**  
Support gRPC protocol in addition to HTTP.

**Challenges:**
- HTTP/2 requirement
- Protobuf encoding
- Streaming RPCs
- Metadata propagation

---

## 7. Developer Experience

### 7.1 Telephone Client SDKs

**Complexity:** MEDIUM  

**Description:**  
Provide official client libraries for connecting telephones in multiple languages.

**Languages:**
- **Elixir/Phoenix** (reference implementation)
- **Node.js** (JavaScript/TypeScript)
- **Python** (asyncio)
- **Go**
- **Ruby**
- **Java/Kotlin**

**SDK Features:**
- WebSocket connection management
- Automatic token refresh
- Heartbeat handling
- Request/response correlation
- Reconnection with backoff
- Circuit breaker integration

**Example (Node.js):**

```javascript
const { PlugboardTelephone } = require('@plugboard/telephone');

const telephone = new PlugboardTelephone({
  host: 'plugboard.example.com',
  token: 'eyJhbGc...',
  onRequest: async (req) => {
    // Handle proxy request
    const response = await fetch(`http://localhost:3000${req.path}`, {
      method: req.method,
      headers: req.headers,
      body: req.body
    });
    
    return {
      status: response.status,
      headers: Object.fromEntries(response.headers),
      body: await response.text()
    };
  }
});

await telephone.connect();
```

---

### 7.2 CLI Tool for Telephone Management

**Complexity:** LOW  

**Description:**  
Command-line tool for managing paths, tokens, and telephones.

**Example Usage:**

```bash
# Create path
plugboard path create /api/users

# Generate token
plugboard token create /api/users --description "Production server"

# List active telephones
plugboard telephone list /api/users

# View logs
plugboard logs --path /api/users --follow
```

---

### 7.3 OpenAPI / Swagger Documentation

**Complexity:** LOW  

**Description:**  
Generate OpenAPI specification for Plugboard API endpoints.

**Benefits:**
- Auto-generated API docs
- Client SDK generation
- API testing tools (Postman, Insomnia)

---

## 8. Multi-Tenancy & Isolation

### 8.1 Organizations / Teams

**Complexity:** MEDIUM  

**Description:**  
Add organization/team concept for better multi-tenancy support.

**Schema:**

```sql
CREATE TABLE organizations (
  id BINARY_ID PRIMARY KEY,
  name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE organization_members (
  id BINARY_ID PRIMARY KEY,
  organization_id BINARY_ID NOT NULL REFERENCES organizations(id),
  user_id BINARY_ID NOT NULL REFERENCES users(id),
  role TEXT NOT NULL CHECK (role IN ('owner', 'admin', 'member')),
  UNIQUE(organization_id, user_id)
);

ALTER TABLE paths
ADD COLUMN organization_id BINARY_ID REFERENCES organizations(id);
```

**Benefits:**
- Isolation between teams
- Separate billing
- Admin delegation

---

### 8.2 Resource Quotas

**Complexity:** MEDIUM  

**Description:**  
Enforce quotas on paths, telephones, and requests per organization.

**Quota Types:**
- Max paths per organization
- Max telephones per path
- Max requests per month
- Max bandwidth per month

---

## 9. Caddy Integration

### 9.1 Multi-Domain Origin Support

**Complexity:** MEDIUM  

**Description:**  
Integrate Caddy as a reverse proxy layer to enable Plugboard to serve traffic from multiple domain origins. This allows a single Plugboard instance to handle requests across different domains (e.g., `api.example.com`, `app.example.com`, `customer1.saas.com`) with automatic HTTPS certificate management.

**Architecture:**

```
┌─────────────┐
│   Client    │
└──────┬──────┘
       │ HTTPS Request: api.example.com/users
       ▼
┌─────────────────────────────────────┐
│         Caddy Server                │
│  - Automatic HTTPS/TLS              │
│  - Domain-based routing             │
│  - Certificate management           │
└───────────────┬─────────────────────┘
                │ HTTP (internal)
                ▼
┌─────────────────────────────────────┐
│         Plugboard Cluster           │
│  - Path-based routing               │
│  - Telephone management             │
│  - WebSocket tunneling              │
└─────────────────────────────────────┘
```

**Benefits:**
- **Multi-domain support:** Single Plugboard instance serves multiple domains
- **Automatic HTTPS:** Caddy handles Let's Encrypt certificates automatically
- **Domain isolation:** Route different domains to different path hierarchies
- **Zero downtime certificate renewal:** Caddy manages cert lifecycle
- **HTTP/3 & HTTP/2 support:** Modern protocol support out of the box

**Configuration Example:**

```caddyfile
# Caddyfile
api.example.com {
    reverse_proxy localhost:4000 {
        header_up X-Domain api.example.com
    }
}

app.example.com {
    reverse_proxy localhost:4000 {
        header_up X-Domain app.example.com
    }
}

*.saas.example.com {
    reverse_proxy localhost:4000 {
        header_up X-Domain {host}
    }
}
```

**Implementation Tasks:**
- [ ] Add `domain` field to paths table for domain-based routing
- [ ] Update ProxyController to inspect `X-Domain` header
- [ ] Implement domain-aware path matching in MountStore
- [ ] Add Caddy configuration templates for Docker/Kubernetes
- [ ] Document deployment patterns with Caddy
- [ ] Add domain validation and wildcard support
- [ ] Create UI for domain management per path

**Use Cases:**
- **Multi-tenant SaaS:** Each customer gets their own subdomain (`customer1.saas.com`, `customer2.saas.com`)
- **Microservices gateway:** Different services on different domains (`api.example.com`, `admin.example.com`)
- **Development environments:** Separate domains for staging vs production
- **White-label deployments:** Different brands on different domains

---

## Summary

This document outlines planned features and enhancements for Plugboard beyond MVP:

**Performance & Scalability:**
- Request and response body streaming (file uploads, downloads, large data transfers)
- Load balancing strategies (least connections, weighted, latency-based, consistent hashing)
- HTTP/2 support and connection pooling

**Multi-Domain & Routing:**
- Caddy integration for multi-domain origin support
- Header-based routing and path rewriting
- Geographic/multi-region routing

**Security & Authentication:**
- Rate limiting (per-user and per-path)
- Per-path request body size limits (global limit already implemented)
- mTLS telephone authentication
- IP whitelisting/allowlisting

**Observability & Operations:**
- Prometheus metrics export
- Distributed tracing (OpenTelemetry)
- Real-time monitoring dashboard
- Health checks and circuit breaker patterns

**Developer Experience:**
- Telephone client SDKs (Node.js, Python, Go, Ruby)
- CLI tool for telephone management
- OpenAPI/Swagger documentation

**Protocol Support:**
- WebSocket upgrade proxying
- gRPC support

**Multi-Tenancy:**
- Organizations/teams support
- Resource quotas

---

**Questions or suggestions?** Open an issue or discussion on the project repository.
