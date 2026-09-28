# Stage 2 — Deploy MCP Server to Google Cloud Run (via `deploy.sh`)

## 1. Goal of This Stage
Deploy our Stage 0 **FastMCP Order Server** to **Google Cloud Run** using a transparent, well-commented shell script ([`deploy.sh`](./deploy.sh)) using native `gcloud` CLI commands.

---

## 2. What `deploy.sh` Does Step-by-Step

```
┌───────────────────────────────────────────────────────────────┐
│ deploy.sh Execution Flow (Production Zero-Trust Security)     │
├───────────────────────────────────────────────────────────────┤
│ 1. User Input & Confirmation                                  │
│    • Prompts/Confirms PROJECT_ID (default: active project)    │
│    • Prompts/Confirms REGION (default: us-central1)           │
│    • Prompts/Confirms SERVICE_NAME (default: order-mcp-server)│
│                                                               │
│ 2. API Enablement (`gcloud services enable`)                  │
│    • run.googleapis.com                                       │
│    • cloudbuild.googleapis.com                                │
│    • artifactregistry.googleapis.com                          │
│                                                               │
│ 3. Cloud Run Deploy (`gcloud run deploy --source ...`)        │
│    • Builds Dockerfile from `../0 - setup MCP server`         │
│    • Deploys with --no-allow-unauthenticated (Zero-Trust)     │
│                                                               │
│ 4. IAM Permissions Binding (`roles/run.invoker`)              │
│    • Grants Invoker role strictly to Agent Engine identity    │
│    • Blocks public internet & developer interactive access    │
│                                                               │
│ 5. Deployment Confirmation                                    │
│    • Fetches service URL: `gcloud run services describe`      │
│    • Confirms Zero-Trust Service-to-Service configuration     │
└───────────────────────────────────────────────────────────────┘
```

---

## 3. Files in This Folder

| File | Purpose |
| :--- | :--- |
| [`deploy.sh`](./deploy.sh) | The complete, commented bash deployment script. |
| [`test_cloud_run_mcp.py`](./test_cloud_run_mcp.py) | Python test client that connects to the live Cloud Run SSE endpoint, discovers tools, and tests `get_order` / `process_refund`. |
| [`README.md`](./README.md) | Stage explanation and learning guide. |

---

## 4. How to Deploy & Verify

Run the deployment script from this directory:

```bash
cd "2 - deploy MCP on Cloud Run"
./deploy.sh
```

---

## 5. How to Connect Stage 1 ADK Agents to this Live Cloud Run MCP Server

After deployment finishes, copy the printed `SSE URL` and update [`1 - multi agent ADK app/order-assistant/.env`](../1%20-%20multi%20agent%20ADK%20app/order-assistant/.env):

```env
MCP_SERVER_URL=https://order-mcp-server-<hash>.us-central1.run.app/sse
```

Then you can test your local ADK multi-agent app talking to the live Cloud Run MCP server:

```bash
cd "../1 - multi agent ADK app/order-assistant"
agents-cli run "Check order ORD-102 and refund it if eligible."
```
