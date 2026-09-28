# Stage 0 — Setup Simple MCP Server (Local & Cloud Run Ready)

## 1. Goal of This Stage
Build a minimal, standalone **Model Context Protocol (MCP) Server** in Python that exposes e-commerce order & refund tools over **SSE (`/sse`)** so that remote Google ADK agents can dynamically discover and invoke its tools over HTTP/HTTPS.

---

## 2. Architecture & Key Concepts

```
ADK Sub-Agent (McpToolset) ──► GET /sse (Handshake & Tool Discovery)
                           ──► POST /messages/?session_id=... (CallToolRequest)
                                 │
                                 ▼
                    FastMCP Server (`server.py`)
                    ├── Tool 1: `get_order(order_id)`
                    └── Tool 2: `process_refund(order_id, reason)`
```

### Important Learnings & Gotchas
1. **Pin `mcp>=1.6.0,<2.0.0`**:
   - In `mcp 2.x`, `FastMCP` was renamed to `MCPServer` with breaking API changes.
   - `google-adk` (`McpToolset`) currently relies on `mcp<2.0.0`. Always pin `mcp>=1.6.0,<2.0.0` in [`requirements.txt`](./requirements.txt).
2. **Transport Mode (`sse` vs `stdio`)**:
   - `stdio` only works when the MCP server runs as a local subprocess on the same machine.
   - For **Cloud Run** (and remote multi-agent systems), the server must listen on `0.0.0.0` and expose an HTTP/SSE endpoint (`mcp.run(transport="sse")`).
3. **Port Configuration (`PORT` env var)**:
   - Cloud Run automatically injects `PORT=8080`.
   - Locally, port `8080` is often occupied by other services, so [`server.py`](./server.py) defaults to `8085` locally (`int(os.environ.get("PORT", 8085))`) while [`Dockerfile`](./Dockerfile) sets `ENV PORT=8080` for Cloud Run.

---

## 3. Files in This Folder

| File | Purpose |
| :--- | :--- |
| [`server.py`](./server.py) | `FastMCP` server with an in-memory mock database (`ORD-101`, `ORD-102`, `ORD-103`) and 2 tools: `get_order` and `process_refund`. |
| [`requirements.txt`](./requirements.txt) | Lightweight dependencies (`mcp>=1.6.0,<2.0.0`, `uvicorn`). |
| [`Dockerfile`](./Dockerfile) | Container definition for deploying the MCP server to Google Cloud Run. |
| [`test_local_mcp.py`](./test_local_mcp.py) | Standalone Python MCP client script to verify `/sse` handshake, tool discovery, and tool execution locally. |

---

## 4. Step-by-Step: How to Run & Test Locally

### Option A: Using a Persistent Virtual Environment (`.venv`)
```bash
# 1. Create and activate virtual environment
uv venv
source .venv/bin/activate

# 2. Install dependencies
uv pip install -r requirements.txt

# 3. Start the MCP server (Terminal 1)
python server.py
# -> Listening on http://0.0.0.0:8085/sse

# 4. Run the local test client (Terminal 2)
python test_local_mcp.py
```

### Option B: One-Line Ephemeral Run via `uv`
```bash
uv run --with "mcp>=1.6.0,<2.0.0" --with uvicorn python server.py
```

---

## 5. Expected Output (`test_local_mcp.py`)

```text
Connecting to MCP Server at http://127.0.0.1:8085/sse ...

Discovered MCP Tools:
 - get_order: Look up order details and shipping status by order_id (e.g., ORD-101, ORD-102, ORD-103).
 - process_refund: Process a refund for an order given its order_id and the reason for the refund.

Calling tool: get_order(order_id='ORD-102')...
Result: {
  "found": true,
  "order": {
    "order_id": "ORD-102",
    "customer": "Bob",
    "item": "Mechanical Keyboard",
    "price": 85.0,
    "status": "delayed",
    "card_number": "4532-1234-5678-9014",
    "refunded": false
  }
}

Calling tool: process_refund(order_id='ORD-102', reason='Order delayed')...
Result: {
  "success": true,
  "message": "Refund of $85.00 processed for ORD-102 (Mechanical Keyboard)."
}
```
