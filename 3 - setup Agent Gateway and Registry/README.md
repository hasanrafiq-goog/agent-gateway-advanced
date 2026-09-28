# Stage 3: Setup Egress Agent Gateway and Agent Registry

## Overview

In **Stage 3**, we provision the Egress Agent Gateway in `AGENT_TO_ANYWHERE` mode and register our private Cloud Run MCP server in Google Cloud Agent Registry.

```
                      ┌────────────────────────────────────────────────────────┐
                      │           Vertex AI Agent Engine (Stage 4)             │
                      │  • ADK Multi-Agent App with SPIFFE Identity            │
                      └──────────────────────────┬─────────────────────────────┘
                                                 │ (Outbound MCP Tool Request)
                                                 ▼
                      ┌────────────────────────────────────────────────────────┐
                      │        Egress Gateway (`AGENT_TO_ANYWHERE`)            │
                      │  • Governed Outbound Connectivity to Tools             │
                      │  • Agent Registry Tool Discovery & Routing             │
                      │  • TLS Inspection for Model Armor Guardrails (Stage 5) │
                      └──────────────────────────┬─────────────────────────────┘
                                                 │ (Governed Egress)
                                                 ▼
                                    [Cloud Run Private FastMCP Server]
```

---

## 🛠️ Resources Created

1. **Egress Agent Gateway** (`order-agent-gateway`):
   - Mode: `AGENT_TO_ANYWHERE` (Google Managed)
   - Protocols: `MCP`
   - Governs outbound agent traffic to external MCP servers and APIs.
2. **Agent Registry Service Registrations**:
   - `order-mcp-server`: FastMCP server endpoint (`/sse`) on Cloud Run.
3. **Gateway Root CA Export**:
   - Automatically exports `agentGatewayCard.rootCertificates` to `../1 - multi agent ADK app/order-assistant/app/gateway_ca.crt` so that Stage 4 can package it into the production container for TLS inspection.

---

## 🚀 Deployment

Run the automated deployment script:

```bash
chmod +x deploy.sh
./deploy.sh
```
