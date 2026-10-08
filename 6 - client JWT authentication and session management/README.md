# Stage 6: Client JWT Authentication & Session Handshake

This stage demonstrates how an external client or front-end application sends their own **end-user JWT token** (containing user entitlements, roles, and authorization scopes) during an initial handshake, and how the multi-agent system deployed on **Vertex AI Agent Engine** maintains that security context throughout the conversation.

---

## 🎯 The Enterprise Problem

In enterprise environments:
1. **End users authenticate with their own Identity Provider** (Okta, Entra ID, Auth0, Ping, Keycloak). The client front-end holds a JWT token specifying the user identity (`sub`, `email`), roles (`customer`, `support_lead`), and access scopes (`orders:read`, `orders:status`).
2. **Clients do not want to re-send this JWT on every message turn**, nor can standard Google Cloud control plane endpoints (like Vertex AI `:streamQuery`) be expected to pass arbitrary non-Google headers through to downstream containers.
3. **The Agent must enforce and propagate this context**: When the agent delegates tasks to sub-agents and invokes downstream MCP tools across the Google Cloud Agent Gateway, the downstream service (e.g. Order MCP Server on Cloud Run) must know *who* the end user is and *what scopes* they have, while preserving Google IAM infrastructure security.

---

## 🏛️ Architecture & Lifecycle

```
[Client Front-End / API Caller]
        │
        │ 1. Initial Handshake: POST /api/session/init
        │    Headers:
        │      Authorization: Bearer <GCP_OAUTH_TOKEN>   (Google IAM authentication)
        │      X-User-Token: <END_USER_JWT>              (Client auth & scopes)
        ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Vertex AI Agent Engine Reverse-Proxy Passthrough (/api/*)                              │
│ • Delivers all custom HTTP headers (X-User-Token) directly to container                │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Container: FastAPI Application (fast_api_app.py)                                       │
│ 1. Extracts & safely decodes claims from X-User-Token (sub, email, scopes, roles)      │
│ 2. Creates an ADK Session via process-wide session service (VertexAiSessionService)     │
│ 3. Pre-populates session.state with:                                                   │
│      - user_jwt: Raw JWT string                                                        │
│      - user_id: 'customer_bob'                                                         │
│      - user_email: 'bob@example.com'                                                   │
│      - user_scopes: ['orders:read', 'orders:status']                                   │
│      - user_claims: Full decoded payload                                               │
│ 4. Returns: {"status": "success", "session_id": "6153733655995875328", ...}            │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Subsequent Turns: POST :streamQuery (Standard Vertex AI Endpoint)                      │
│ • Client sends standard prompt + session_id                                            │
│ • Agent Engine loads session state containing user_jwt and scopes                      │
│ • Sub-agents (order_tracker) execute delegated tasks                                   │
│ • McpToolset dynamic header_provider (get_auth_headers):                                │
│     Attaches X-User-Token: <user_jwt> on outbound MCP requests                          │
│ • Outbound call passes through Agent Gateway with Model Armor SDP & Tool Governance    │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 📂 Code Organization: Step 1 vs Step 6

* **Implementation in Stage 1 (`1 - multi agent ADK app/order-assistant`)**:
  * [`app/fast_api_app.py`](../1%20-%20multi%20agent%20ADK%20app/order-assistant/app/fast_api_app.py): Exposes `@app.post("/api/session/init")` to decode the JWT, create the session, and initialize `session.state`.
  * [`app/agent.py`](../1%20-%20multi%20agent%20ADK%20app/order-assistant/app/agent.py): Dynamic `get_auth_headers(context)` reads `context.state["user_jwt"]` and propagates it on outbound MCP requests.
  * [`app/app_utils/services.py`](../1%20-%20multi%20agent%20ADK%20app/order-assistant/app/app_utils/services.py): Provides the process-wide `ResilientSessionService` ensuring sessions created via the custom endpoint are shared seamlessly with reasoning engine streaming queries.
* **Testing and Execution in Stage 6**:
  * This stage provides the standalone verification script [`test_jwt_session.sh`](./test_jwt_session.sh) and manual curl recipes to demonstrate this capability to customers and technical reviewers.

---

## 🚀 Live Verification Recipes (Using curl)

### 1. Generate a Test JWT

Generate a mock customer JWT with `sub: customer_bob` and scopes `orders:read`, `orders:status`:

```bash
JWT=$(python3 -c '
import base64, json
header = base64.urlsafe_b64encode(json.dumps({"alg":"HS256","typ":"JWT"}).encode()).decode().rstrip("=")
payload = base64.urlsafe_b64encode(json.dumps({
    "sub": "customer_bob",
    "email": "bob@example.com",
    "scopes": ["orders:read", "orders:status"],
    "roles": ["customer"]
}).encode()).decode().rstrip("=")
print(f"{header}.{payload}.mock_signature")
')
echo "Generated JWT: $JWT"
```

### 2. Handshake: Call `/api/session/init`

Send the JWT once via the `X-User-Token` header:

```bash
TOKEN=$(gcloud auth application-default print-access-token)
RE_RESOURCE_ID=$(grep '"remote_agent_runtime_id"' "../1 - multi agent ADK app/order-assistant/deployment_metadata.json" | cut -d'"' -f4)

INIT_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-User-Token: ${JWT}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/${RE_RESOURCE_ID}/api/session/init")

echo "$INIT_RESP" | jq .
SESSION_ID=$(echo "$INIT_RESP" | jq -r '.session_id')
echo "Captured Session ID: $SESSION_ID"
```

**Expected Response**:
```json
{
  "status": "success",
  "session_id": "6153733655995875328",
  "user_id": "customer_bob",
  "scopes": ["orders:read", "orders:status"],
  "claims": {
    "sub": "customer_bob",
    "email": "bob@example.com",
    "scopes": ["orders:read", "orders:status"],
    "roles": ["customer"]
  }
}
```

### 3. Verify Session State Retention

Inspect the stored session state via the GET endpoint:

```bash
curl -s \
  -H "Authorization: Bearer ${TOKEN}" \
  "https://us-central1-aiplatform.googleapis.com/reasoningEngines/v1/${RE_RESOURCE_ID}/api/session/${SESSION_ID}?user_id=customer_bob" | jq .
```

**Expected Response**:
```json
{
  "session_id": "6153733655995875328",
  "user_id": "customer_bob",
  "state": {
    "user_jwt": "eyJhbGciOiAiSFMyNTYiLCAidHlwIjogIkpXVCJ9...",
    "user_id": "customer_bob",
    "user_email": "bob@example.com",
    "user_scopes": ["orders:read", "orders:status"]
  }
}
```

### 4. Query Agent via Standard Vertex AI `:streamQuery`

Query the agent normally using only the returned `session_id`. Notice that no custom token header is needed here:

```bash
PROJECT_ID=$(gcloud config get-value project)
RE_NUMERIC_ID=$(basename "$RE_RESOURCE_ID")

curl --no-buffer -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "class_method": "async_stream_query",
    "input": {
      "message": "What is the status of my order ORD-102?",
      "user_id": "customer_bob",
      "session_id": "'"${SESSION_ID}"'"
    }
  }' \
  "https://us-central1-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_ID}/locations/us-central1/reasoningEngines/${RE_NUMERIC_ID}:streamQuery"
```

**Expected Streamed Output**:
```text
Here are the details for your order ORD-102:
• Item: Mechanical Keyboard ($85.00)
• Status: Delayed
• Payment Card Number: [CREDIT_CARD_NUMBER]
```

---

## 🛡️ Enterprise Security Summary

| Feature | Mechanism | Benefit |
| :--- | :--- | :--- |
| **Identity Delegation** | Client JWT in `X-User-Token` | Preserves end-user identity and entitlements across the session |
| **No Per-Message Token Overhead** | Single handshake at session init | Stream queries use standard lightweight session tokens |
| **Outbound Tool Authentication** | Dynamic context-aware MCP header provider | Cloud Run tool server validates user scopes before executing tools |
| **PII & Data Redaction** | Regional Model Armor on Agent Gateway | Sensitive fields (credit cards) are masked inline regardless of user scopes |
