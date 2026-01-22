# Telephone Sidecar: WebSocket Proxy Implementation Guide

This document describes the changes required in the Telephone sidecar to support WebSocket proxying through Plugboard.

## Overview

Plugboard now supports proxying WebSocket connections from clients through to backend services. This requires the Telephone sidecar to:

1. Handle new WebSocket-related Phoenix Channel events
2. Manage WebSocket connections to backend services
3. Forward frames bidirectionally between Plugboard and backend

## Architecture

```
Client                    Plugboard                    Telephone              Backend
  │                          │                            │                      │
  │ WebSocket Upgrade        │                            │                      │
  │ ─────────────────────────►                            │                      │
  │                          │                            │                      │
  │                          │ ws_connect                 │                      │
  │                          │ ───────────────────────────►                      │
  │                          │                            │                      │
  │                          │                            │ WebSocket Connect    │
  │                          │                            │ ─────────────────────►
  │                          │                            │                      │
  │                          │                            │ ◄─────────────────────
  │                          │                            │   Connected          │
  │                          │                            │                      │
  │                          │ ws_connected               │                      │
  │                          │ ◄───────────────────────────                      │
  │                          │                            │                      │
  │ ◄─────────────────────────                            │                      │
  │   101 Switching          │                            │                      │
  │                          │                            │                      │
  │ ═══════════════════════════ Bidirectional Frames ═══════════════════════════│
  │                          │                            │                      │
  │ Frame                    │                            │                      │
  │ ─────────────────────────►                            │                      │
  │                          │ ws_frame                   │                      │
  │                          │ ───────────────────────────►                      │
  │                          │                            │ Frame                │
  │                          │                            │ ─────────────────────►
  │                          │                            │                      │
  │                          │                            │ ◄─────────────────────
  │                          │                            │   Frame              │
  │                          │ ws_frame                   │                      │
  │                          │ ◄───────────────────────────                      │
  │ ◄─────────────────────────                            │                      │
  │   Frame                  │                            │                      │
  │                          │                            │                      │
```

## Protocol Specification

### Events from Plugboard (Handle These)

#### 1. `ws_connect` - Client Wants to Connect to Backend WebSocket

Received when a client initiates a WebSocket connection that should be proxied.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "path": "/websocket",
  "query_string": "token=abc&room=123",
  "headers": {
    "sec-websocket-protocol": "graphql-ws, wamp",
    "origin": "https://example.com",
    "authorization": "Bearer xyz",
    "cookie": "session=abc"
  }
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | Unique identifier for this connection. Use this to correlate all subsequent messages. |
| `path` | string | Path to connect to on the backend (e.g., `/websocket`, `/socket/websocket`) |
| `query_string` | string | Query parameters from original request |
| `headers` | object | Headers to forward to backend (includes subprotocols, auth, etc.) |

**Required Actions:**
1. Parse the `connection_id` and store it for this connection
2. Build the backend WebSocket URL: `ws://localhost:{BACKEND_PORT}{path}?{query_string}`
3. Extract `sec-websocket-protocol` header for subprotocol negotiation
4. Establish WebSocket connection to backend
5. Send `ws_connected` on success or `ws_error` on failure

**Subprotocol Handling:**
- If `sec-websocket-protocol` header is present, pass it to the backend during handshake
- The backend will select a subprotocol (or none)
- Include the selected subprotocol in `ws_connected` response

#### 2. `ws_frame` - Forward Frame to Backend

Received when client sends a WebSocket frame to forward to the backend.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "opcode": "text",
  "data": "eyJxdWVyeSI6ICJ7IHVzZXJzIHsgaWQgbmFtZSB9IH0ifQ=="
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | Connection to forward to |
| `opcode` | string | Frame type: `"text"`, `"binary"`, `"ping"`, `"pong"` |
| `data` | string | Base64-encoded frame data |

**Required Actions:**
1. Look up the backend WebSocket connection by `connection_id`
2. Base64-decode the `data` field
3. Send the frame to the backend with the appropriate opcode
4. Handle errors (connection closed, etc.) by sending `ws_error`

#### 3. `ws_close` - Client Closed Connection

Received when the client closes their WebSocket connection.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "code": 1000,
  "reason": "Client disconnected"
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | Connection to close |
| `code` | integer | WebSocket close code (1000 = normal, 1001 = going away, etc.) |
| `reason` | string | Close reason message |

**Required Actions:**
1. Look up the backend WebSocket connection by `connection_id`
2. Send close frame to backend with the provided code and reason
3. Clean up the connection from your connection map
4. No response needed (connection is being closed)

---

### Events to Send to Plugboard

#### 1. `ws_connected` - Backend Connection Established

Send when you successfully connect to the backend WebSocket.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "protocol": "graphql-ws"
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | The connection ID from `ws_connect` |
| `protocol` | string (optional) | Selected subprotocol (if backend selected one) |

**Send via:** `push` on the Phoenix Channel

#### 2. `ws_frame` - Frame from Backend

Send when you receive a frame from the backend WebSocket.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "opcode": "text",
  "data": "eyJkYXRhIjogeyJ1c2VycyI6IFt7ImlkIjogMSwgIm5hbWUiOiAiSm9obiJ9XX19"
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | The connection this frame belongs to |
| `opcode` | string | Frame type: `"text"`, `"binary"`, `"ping"`, `"pong"` |
| `data` | string | Base64-encoded frame data |

**Important:** All binary data must be Base64-encoded for transport over Phoenix Channels (JSON).

#### 3. `ws_closed` - Backend Closed Connection

Send when the backend WebSocket closes the connection.

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "code": 1000,
  "reason": "Normal closure"
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | The connection that closed |
| `code` | integer | WebSocket close code from backend |
| `reason` | string | Close reason from backend |

#### 4. `ws_error` - Error Occurred

Send when an error occurs (connection failed, backend unreachable, etc.).

```json
{
  "connection_id": "550e8400-e29b-41d4-a716-446655440000",
  "reason": "connection_refused"
}
```

**Fields:**
| Field | Type | Description |
|-------|------|-------------|
| `connection_id` | string (UUID) | The connection that errored |
| `reason` | string | Error description |

**Common Error Reasons:**
- `"connection_refused"` - Backend is not accepting connections
- `"connection_timeout"` - Backend didn't respond in time
- `"invalid_upgrade"` - Backend rejected WebSocket upgrade
- `"backend_error"` - Generic backend error

---

## Implementation Guide

### Connection Manager

You'll need a connection manager to track active WebSocket connections:

```
ConnectionManager
├── connections: Map<connection_id, BackendWebSocket>
├── connect(connection_id, url, headers) -> Result
├── send_frame(connection_id, opcode, data) -> Result
├── close(connection_id, code, reason) -> Result
└── handle_backend_event(connection_id, event) -> void
```

### Pseudocode Implementation

```python
# Connection storage
ws_connections = {}

# Handle ws_connect event
def handle_ws_connect(event):
    connection_id = event["connection_id"]
    path = event["path"]
    query_string = event["query_string"]
    headers = event["headers"]
    
    # Build backend URL
    backend_url = f"ws://localhost:{BACKEND_PORT}{path}"
    if query_string:
        backend_url += f"?{query_string}"
    
    # Extract subprotocols
    subprotocols = None
    if "sec-websocket-protocol" in headers:
        subprotocols = headers["sec-websocket-protocol"].split(",")
        subprotocols = [s.strip() for s in subprotocols]
    
    try:
        # Connect to backend
        ws = WebSocket.connect(
            backend_url,
            subprotocols=subprotocols,
            extra_headers=headers
        )
        
        # Store connection
        ws_connections[connection_id] = ws
        
        # Start receiving frames in background
        start_receiver(connection_id, ws)
        
        # Send success
        channel.push("ws_connected", {
            "connection_id": connection_id,
            "protocol": ws.selected_subprotocol
        })
        
    except Exception as e:
        channel.push("ws_error", {
            "connection_id": connection_id,
            "reason": str(e)
        })

# Handle ws_frame event
def handle_ws_frame(event):
    connection_id = event["connection_id"]
    opcode = event["opcode"]
    data = base64.decode(event["data"])
    
    ws = ws_connections.get(connection_id)
    if not ws:
        return  # Connection already closed
    
    try:
        if opcode == "text":
            ws.send_text(data.decode("utf-8"))
        elif opcode == "binary":
            ws.send_binary(data)
        elif opcode == "ping":
            ws.send_ping(data)
        elif opcode == "pong":
            ws.send_pong(data)
    except Exception as e:
        channel.push("ws_error", {
            "connection_id": connection_id,
            "reason": str(e)
        })

# Handle ws_close event
def handle_ws_close(event):
    connection_id = event["connection_id"]
    code = event["code"]
    reason = event["reason"]
    
    ws = ws_connections.pop(connection_id, None)
    if ws:
        ws.close(code, reason)

# Background receiver for backend frames
def start_receiver(connection_id, ws):
    def receive_loop():
        try:
            while True:
                frame = ws.receive()
                
                channel.push("ws_frame", {
                    "connection_id": connection_id,
                    "opcode": frame.opcode,
                    "data": base64.encode(frame.data)
                })
        
        except WebSocketClosed as e:
            channel.push("ws_closed", {
                "connection_id": connection_id,
                "code": e.code,
                "reason": e.reason
            })
            ws_connections.pop(connection_id, None)
        
        except Exception as e:
            channel.push("ws_error", {
                "connection_id": connection_id,
                "reason": str(e)
            })
            ws_connections.pop(connection_id, None)
    
    # Start in background thread/task
    spawn(receive_loop)
```

---

## WebSocket Close Codes Reference

| Code | Name | Description |
|------|------|-------------|
| 1000 | Normal Closure | Normal connection closure |
| 1001 | Going Away | Endpoint going away (server shutdown, browser navigating) |
| 1002 | Protocol Error | Protocol error occurred |
| 1003 | Unsupported Data | Received unsupported data type |
| 1006 | Abnormal Closure | Connection closed abnormally (no close frame) |
| 1007 | Invalid Data | Invalid message data |
| 1008 | Policy Violation | Policy violation |
| 1009 | Message Too Big | Message too large |
| 1010 | Missing Extension | Required extension not negotiated |
| 1011 | Internal Error | Unexpected server error |
| 1014 | Bad Gateway | Backend unavailable (custom, used by Plugboard) |
| 1015 | TLS Handshake | TLS handshake failure |

---

## Testing

### Manual Testing

1. Start Plugboard with a mount point configured
2. Start Telephone sidecar connected to that mount point
3. Start a backend service with a WebSocket endpoint
4. Connect a WebSocket client to Plugboard:

```bash
# Using websocat
websocat ws://localhost:4000/call/api/websocket

# Or with domain affinity
websocat ws://api.example.com/websocket
```

### Test Scenarios

1. **Basic connection** - Client connects, backend accepts
2. **Subprotocol negotiation** - Client requests `graphql-ws`, backend accepts
3. **Text frames** - Send/receive text messages
4. **Binary frames** - Send/receive binary data
5. **Client closes** - Client sends close frame
6. **Backend closes** - Backend sends close frame
7. **Backend unreachable** - Backend service not running
8. **Backend rejects** - Backend rejects WebSocket upgrade
9. **Telephone disconnect** - Telephone disconnects while WebSocket active

---

## Configuration

No additional configuration is required in Telephone for WebSocket support. The existing Phoenix Channel connection is reused for WebSocket proxy messages.

The following Plugboard environment variables control WebSocket proxy behavior:

| Variable | Description | Default |
|----------|-------------|---------|
| `WEBSOCKET_PROXY_ENABLED` | Enable/disable WebSocket proxying | `true` |
| `WEBSOCKET_CONNECT_TIMEOUT_MS` | Timeout for backend connection | `5000` |
| `WEBSOCKET_MAX_FRAME_SIZE` | Maximum frame size in bytes | `1048576` |
| `WEBSOCKET_IDLE_TIMEOUT_MS` | Idle timeout before closing | `300000` |

---

## Backward Compatibility

WebSocket proxy events are new and will not affect existing HTTP proxy functionality. Telephone sidecars that don't implement WebSocket handling will simply ignore `ws_*` events (Phoenix Channel default behavior).

Clients attempting WebSocket connections to sidecars without WebSocket support will receive a timeout error after `WEBSOCKET_CONNECT_TIMEOUT_MS` (default 5 seconds).

---

## Error Handling Best Practices

1. **Always clean up connections** - On any error, remove the connection from your map
2. **Send appropriate close codes** - Use standard WebSocket close codes
3. **Log connection lifecycle** - Log connect, disconnect, and errors for debugging
4. **Handle concurrent connections** - Each `connection_id` is independent
5. **Graceful shutdown** - On Telephone disconnect, close all backend WebSockets

---

## Questions?

If you have questions about implementing WebSocket proxy support in the Telephone sidecar, please refer to:

- `lib/plugboard_web/channels/telephone_channel.ex` - Server-side handling
- `lib/plugboard_web/websocket/proxy_handler.ex` - WebSocket proxy handler
- `lib/plugboard_web/plugs/websocket_proxy_plug.ex` - WebSocket detection and routing
