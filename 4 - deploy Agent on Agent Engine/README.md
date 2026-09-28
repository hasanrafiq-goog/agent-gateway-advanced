# Stage 4 — Deploy ADK Multi-Agent App to Vertex AI Agent Engine with Agent Gateway Egress & SPIFFE Agent Identity

## 1. Goal of This Stage
Deploy our **Stage 1 ADK 2.0 Multi-Agent App** to **Vertex AI Agent Engine (Agent Runtime)** and bind it to **Agent Gateway** using the **SPIFFE Agent Identity Protocol** so that:
1. The agent runs on Google's managed agent runtime with a dedicated, cryptographically unique **SPIFFE Agent Identity**:
   `principal://agents.global.org-<ORG_ID>.system.id.goog/resources/aiplatform/projects/<PROJECT_NUM>/locations/<REGION>/reasoningEngines/<ENGINE_ID>`
2. **100% of outbound traffic** (Gemini LLM calls & Cloud Run MCP tool invocations) routes securely through **Agent Gateway** (`order-agent-gateway`).
3. Outbound calls to `order-mcp-server` are governed by:
   - **Agent Gateway IAP Egress Policy (`roles/iap.egressor`)** on Agent Registry.
   - **Zero-Trust Cloud Run IAM Policy (`roles/run.invoker`)** targeting the Agent Identity and caller SAs with dynamic OIDC ID token resolution.

---

## 2. End-to-End Architecture & Traffic Flow

```
User Query ──► `agents-cli run --url ... --mode adk`
                     │
                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Vertex AI Agent Engine (Agent Runtime in `us-central1`)                │
│ • Reasoning Engine running ADK 2.0 Multi-Agent Container               │
│ • Cryptographic SPIFFE Agent Identity:                                 │
│   `principal://agents.global.org-<ORG_ID>.system.id.goog/...`     │
│ • Resolves OIDC ID Token dynamically via `header_provider`             │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │ Outbound call to `MCP_SERVER_URL`
                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Agent Gateway (`order-agent-gateway` in `AGENT_TO_ANYWHERE` Mode)      │
│ 1. Intercepts outbound HTTPS connection                                │
│ 2. Validates caller against IAP Egress policy (`roles/iap.egressor`)   │
│ 3. Resolves target URL in Agent Registry (`services/order-mcp-server`) │
│ 4. Passes MCP JSON-RPC frame (`get_order`, `process_refund`)           │
│ 5. Forwards authorized call with OIDC bearer token to Cloud Run        │
└────────────────────────────────────┬───────────────────────────────────┘
                                     │ Governed IAM Egress
                                     ▼
┌────────────────────────────────────────────────────────────────────────┐
│ Google Cloud Run (`order-mcp-server` --no-allow-unauthenticated)       │
│ • Validates `roles/run.invoker` for caller identity                    │
│ • Executes `get_order("ORD-101")` & `process_refund("ORD-101")`        │
└────────────────────────────────────────────────────────────────────────┘
```

---

## 3. Why SPIFFE Agent Identity Protocol? (Zero-Trust vs Shared Service Agent)

| Feature | Legacy Platform Service Agent | SPIFFE Agent Identity Protocol |
| :--- | :--- | :--- |
| **Principal Format** | `serviceAccount:service-<NUM>@gcp-sa-aiplatform-re...` | `principal://agents.global.org-<ORG_ID>.system.id.goog/resources/.../reasoningEngines/<ID>` |
| **Granularity** | **Project-Wide**: All agents in the project share the same SA. | **Instance-Specific**: Unique to this individual agent deployment. |
| **Isolation** | Compromising one agent exposes all project tools. | True **Zero-Trust**: Only this specific Reasoning Engine can invoke the MCP server. |

---

## 4. Files in This Folder

| File | Purpose |
| :--- | :--- |
| [`deploy.sh`](./deploy.sh) | The complete automated deployment script (updates `.env` -> deploys to Agent Engine with `--agent-identity` -> binds to Agent Gateway -> fetches SPIFFE principal -> applies `roles/run.invoker` & `roles/iap.egressor` -> runs live test). |
| [`README.md`](./README.md) | Stage explanation, architecture diagrams, and verification commands. |

---

## 5. How to Execute

Run the deployment script from this directory:

```bash
cd "4 - deploy Agent on Agent Engine"
chmod +x deploy.sh
./deploy.sh
```

**What `deploy.sh` does automatically:**
1. Updates [`1 - multi agent ADK app/order-assistant/.env`](../1%20-%20multi%20agent%20ADK%20app/order-assistant/.env) with your live Cloud Run MCP URL (`https://order-mcp-server-...run.app/sse`).
2. Enhances the project with `agents-cli scaffold enhance . --deployment-target agent_runtime`.
3. Runs `agents-cli deploy --agent-identity` to build and deploy the container to Vertex AI Agent Engine.
4. Binds the reasoning engine to `order-agent-gateway` via the `agentGatewayConfig.agentToAnywhereConfig` deployment spec.
5. Dynamically queries `spec.effectiveIdentity` and binds `roles/run.invoker` to the **SPIFFE Agent Identity** and caller SAs on Cloud Run.
6. Configures `roles/iap.egressor` on the Agent Registry for the deployed agent identity.
7. Runs a remote live test using `agents-cli run --url <REASONING_ENGINE_URL> --mode adk`!

---

## 6. How to Query Your Live Deployed Agent

```bash
# Query the live deployed reasoning engine via ADK streaming mode
RE_URL="https://${REGION:-us-central1}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION:-us-central1}/reasoningEngines/${REASONING_ENGINE_ID}"

agents-cli run \
  --url "$RE_URL" \
  --mode adk \
  "Can you check the status and payment card of order ORD-102?"
```

