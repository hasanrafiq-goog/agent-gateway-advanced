# Production Multi-Agent Architecture with Google Cloud Agent Gateway & SPIFFE Identity

An enterprise-grade, end-to-end reference architecture implementing governed multi-agent systems using the **Google Agent Development Kit (ADK 2.0)**, **Vertex AI Agent Engine (Reasoning Engine)**, **FastMCP (Model Context Protocol)**, and **Google Cloud Agent Gateway**.

Governed by cryptographic **SPIFFE Agent Identity**, **Regional Model Armor with Sensitive Data Protection (DLP SDP)**, and **MCP Protocol-Level Tool Governance**.

---

## 📑 Table of Contents

1. [Executive Summary & Purpose](#-executive-summary--purpose)
2. [Core Goals & Enterprise Challenges Solved](#-core-goals--enterprise-challenges-solved)
3. [End-to-End System Architecture](#-end-to-end-system-architecture)
4. [Technology Stack & Feature Coverage](#-technology-stack--feature-coverage)
5. [The Security Model: Defense-in-Depth](#-the-security-model-defense-in-depth)
6. [Stage-by-Stage Walkthrough](#-stage-by-stage-walkthrough)
   - [Stage 0: FastMCP Tool Server](#stage-0-fastmcp-order--refund-server)
   - [Stage 1: Multi-Agent ADK Application](#stage-1-adk-20-multi-agent-application)
   - [Stage 2: Private Cloud Run Deployment](#stage-2-zero-trust-cloud-run-deployment)
   - [Stage 3: Egress Agent Gateway & Registry](#stage-3-setup-egress-agent-gateway--agent-registry)
   - [Stage 4: Agent Engine & SPIFFE Identity](#stage-4-deploy-to-vertex-ai-agent-engine)
   - [Stage 5: Model Armor SDP & Tool Denial](#stage-5-egress-model-armor-sdp--mcp-tool-governance)
7. [Live Verification & Proof of Enforcement](#-live-verification--proof-of-enforcement)
8. [Prerequisites & Portability Guide](#-prerequisites--portability-guide)

---

## 🎯 Executive Summary & Purpose

Modern autonomous AI agents require direct integration with downstream databases, enterprise tools, and payment APIs. However, allowing LLM agents to communicate unconstrained over the public internet introduces significant enterprise risks:

- **Data Exfiltration & PII Leaks**: Unsanitized tool responses expose sensitive payment data (credit card numbers, SSNs, personal identity info) directly to LLM context windows and downstream client responses.
- **Over-Privileged Service Accounts**: Conventional agents share project-wide platform service accounts (`gcp-sa-aiplatform-re`), violating the Principle of Least Privilege.
- **Uncontrolled Tool Execution**: Malicious prompt injections or misaligned agent logic can trigger high-risk actions (e.g. processing unauthorized refunds or deleting database records).
- **Network Perimeter Blind Spots**: Without egress traffic inspection, organizations lack visibility into outbound agentic API and MCP interactions.

**This repository provides a production-grade solution** built on the Google Cloud Gemini Enterprise Agent Platform. It demonstrates how to combine **ADK 2.0 multi-agent task orchestration** with **Agent Gateway perimeter governance**, enforcing cryptographic identity, inline PII masking, and protocol-level tool restrictions.

---

## 🏆 Core Goals & Enterprise Challenges Solved

| Enterprise Challenge | Traditional / Vulnerable Approach | This Reference Architecture's Solution |
| :--- | :--- | :--- |
| **Tool Response Sensitive Data** | Raw JSON payloads with credit card numbers leak directly into LLM prompts and user output. | **Model Armor with Cloud DLP (SDP)** on `CONTENT_AUTHZ` intercepts egress responses at the gateway, masking credit cards to `[CREDIT_CARD_NUMBER]`. |
| **Unauthorized Tool Execution** | Agent has unrestricted access to call all tools exposed on the server. | **Agent Gateway MCP Tool Governance** on `REQUEST_AUTHZ` parses JSON-RPC bodies and blocks restricted tools (`process_refund`) with **403 Forbidden**. |
| **Identity & Access Management** | Broad, project-wide service accounts where compromising one agent compromises all tools. | **SPIFFE Agent Identity Protocol** (`principal://agents.global.org-...`) grants instance-specific `roles/run.invoker` strictly to this single reasoning engine. |
| **Tool Authentication** | Publicly accessible tool servers or static API keys baked into container code. | **Zero-Trust Cloud Run (`--no-allow-unauthenticated`)** with dynamic OIDC ID token resolution per request. |
| **Multi-Agent Orchestration** | Rigid, hardcoded code graphs or monolithic single-prompt agents. | **ADK 2.0 Dynamic Delegation (`mode="task"`)** with on-demand **Skill Loading** that unlocks MCP tools only when required. |
| **TLS Egress Inspection** | Egress proxies break Python/gRPC SSL handshakes due to untrusted inspection CAs. | **Dynamic CA Injection Pipeline** automatically extracts and mounts `agentGatewayCard.rootCertificates` into container trust stores. |

---

## 🏛️ End-to-End System Architecture

```
[User / Client CLI]
        │
        ▼  (streamQuery HTTPS)
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Vertex AI Agent Engine (Reasoning Engine in us-central1)                               │
│ • Root Coordinator Agent (ADK 2.0 Task Delegation mode="task")                         │
│ • Sub-Agents: order_tracker & refund_specialist                                        │
│ • Dynamic Skills: order-tracking & refund-policy (unlocks MCP tools on demand)         │
│ • Cryptographic SPIFFE Agent Identity:                                                 │
│   principal://agents.global.org-<ORG_ID>.system.id.goog/.../reasoningEngines/<ID>       │
│ • Gateway TLS Inspection CA trusted via /tmp/ca-bundle-custom.crt                       │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Outbound Call (MCP_SERVER_URL)
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Google Cloud Agent Gateway (Google-Managed AGENT_TO_ANYWHERE Egress Mode)              │
│                                                                                        │
│   [LAYER 1: MCP Tool Governance Policy - REQUEST_AUTHZ]                                │
│   • Parses MCP JSON-RPC frame in HTTP request                                          │
│   • IF method == "tools/call" AND params.name == "process_refund":                     │
│         ──► BLOCKED WITH HTTP 403 FORBIDDEN ❌ (Refund tool execution denied)          │
│   • IF method == "tools/call" AND params.name == "get_order":                          │
│         ──► ALLOWED THROUGH TO DESTINATION ✅                                          │
│                                                                                        │
│   [LAYER 2: Inline TLS Decryption & Service Extension Callout]                         │
│   • Intercepts outbound TLS connection using internal Root CA                          │
│   • Calls Regional Model Armor (modelarmor.us-central1.rep.googleapis.com)             │
│                                                                                        │
│   [LAYER 3: Model Armor & Sensitive Data Protection - CONTENT_AUTHZ]                   │
│   • Request Template: Blocks prompt injection, jailbreaks, and malicious URIs          │
│   • Response Template: Intercepts raw tool output from Cloud Run                        │
│   • Cloud DLP (SDP): Inspects for CREDIT_CARD_NUMBER and de-identifies inline          │
│         "card_number": "4532-1234-5678-9014" ──► "card_number": "[CREDIT_CARD_NUMBER]" │
└───────────────────────────────────────────┬────────────────────────────────────────────┘
                                            │ Governed Zero-Trust Egress
                                            ▼
┌────────────────────────────────────────────────────────────────────────────────────────┐
│ Google Cloud Run Private FastMCP Server (order-mcp-server)                             │
│ • Zero Public Access (--no-allow-unauthenticated)                                      │
│ • Validates roles/run.invoker for SPIFFE Agent Identity principal                      │
│ • Python FastMCP Server running over Server-Sent Events (/sse)                         │
│ • Order Database: ORD-101, ORD-102 (Mechanical Keyboard, Bob), ORD-103               │
└────────────────────────────────────────────────────────────────────────────────────────┘
```

---

## 🧰 Technology Stack & Feature Coverage

### 1. Agent Development & Orchestration
- **Google Agent Development Kit (ADK 2.0)**: Built using `google-adk >= 2.0.0` with `Agent(mode="task")` for dynamic task delegation.
- **ADK Skills System (`SkillToolset`)**: Markdown-defined skills with YAML frontmatter (`order-tracking`, `refund-policy`) loaded dynamically via `load_skill`.
- **Dynamic MCP Tool Unlocking**: Downstream tools (`get_order`, `process_refund`) remain invisible and uncallable until the agent loads the corresponding skill.
- **FastMCP (Model Context Protocol)**: Standalone Python MCP server communicating via Server-Sent Events (`/sse`) and JSON-RPC message streams.

### 2. Cloud Infrastructure & Agent Runtime
- **Vertex AI Agent Engine (Reasoning Engine)**: Managed containerized agent runtime supporting streaming queries (`async_stream_query`) and state management.
- **Google Cloud Run**: Serverless container execution for private MCP microservices with autoscaling (0 to 5 instances).
- **Google Cloud Agent Registry**: Centralized service directory for discovering agents, MCP tools, and platform endpoints.

### 3. Perimeter Security & Governance
- **SPIFFE Agent Identity Protocol**: Cryptographic, non-forgeable identity issued to each Reasoning Engine deployment for granular IAM authorization.
- **Google Cloud Agent Gateway (`AGENT_TO_ANYWHERE`)**: Google-managed egress gateway governing all outbound agent traffic.
- **Network Security Authorization Policies (`AuthzPolicy`)**:
  - `REQUEST_AUTHZ`: Header and MCP protocol-level request evaluation.
  - `CONTENT_AUTHZ`: Deep payload inspection of request and response bodies.
- **Service Extensions (`AuthzExtension`)**: Real-time gRPC callout engine integrating Agent Gateway with Regional Model Armor.
- **Regional Model Armor**: Location-bound safety filter evaluating Responsible AI policies, prompt injections, and data sanitization.
- **Cloud Sensitive Data Protection (DLP / SDP)**: Inspect and De-identify templates performing pattern recognition and redaction of payment data.

---

## 🔐 The Security Model: Defense-in-Depth

```
User Query
    │
    ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ Layer 1: Prompt Safety & Jailbreak Defense (Model Armor Request Template)     │
│ • Intercepts adversarial attacks and prompt injections before agent execution │
└──────────────────────────────────────┬────────────────────────────────────────┘
                                       │
                                       ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ Layer 2: MCP Tool Governance (Agent Gateway REQUEST_AUTHZ Policy)             │
│ • Parses MCP JSON-RPC frame; denies dangerous methods (process_refund)        │
└──────────────────────────────────────┬────────────────────────────────────────┘
                                       │
                                       ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ Layer 3: SPIFFE Agent Identity & Cloud Run IAM (roles/run.invoker)            │
│ • Rejects unauthenticated callers; allows only this specific Reasoning Engine │
└──────────────────────────────────────┬────────────────────────────────────────┘
                                       │
                                       ▼
┌───────────────────────────────────────────────────────────────────────────────┐
│ Layer 4: Sensitive Data Protection Redaction (Model Armor Response Template)  │
│ • Inspects tool responses; masks credit cards to [CREDIT_CARD_NUMBER]         │
└──────────────────────────────────────┬────────────────────────────────────────┘
                                       │
                                       ▼
Sanitized Agent Response to Client
```

---

## 📁 Stage-by-Stage Walkthrough

The repository is structured into 6 sequential, modular stages:

```
agent-gateway-advanced/
├── 0 - setup MCP server/                # Stage 0: FastMCP Python Tool Server
├── 1 - multi agent ADK app/             # Stage 1: ADK 2.0 Multi-Agent Application
├── 2 - deploy MCP on Cloud Run/         # Stage 2: Private Cloud Run Deployment
├── 3 - setup Agent Gateway and Registry/# Stage 3: Egress Gateway & Registry Setup
├── 4 - deploy Agent on Agent Engine/    # Stage 4: Agent Engine Deployment & SPIFFE IAM
└── 5 - policy enforcement and tool gov/ # Stage 5: Model Armor SDP & Tool Denial
```

---

### Stage 0: FastMCP Order & Refund Server
- **Folder**: [`0 - setup MCP server/`](./0%20-%20setup%20MCP%20server)
- **Objective**: Implement a standalone Python MCP server using `FastMCP` exposing two tools over Server-Sent Events (`/sse`):
  1. `get_order(order_id)`: Returns customer name, item, shipping status, price, and payment credit card number (`card_number`).
  2. `process_refund(order_id, reason)`: Processes a refund for delayed or damaged items.
- **Local Run**:
  ```bash
  cd "0 - setup MCP server"
  uv run --with "mcp>=1.6.0,<2.0.0" --with uvicorn python server.py
  ```

---

### Stage 1: ADK 2.0 Multi-Agent Application
- **Folder**: [`1 - multi agent ADK app/`](./1%20-%20multi%20agent%20ADK%20app)
- **Objective**: Implement the multi-agent system using Google ADK 2.0:
  - **`root_agent`**: Task coordinator that analyzes the customer's request and routes to sub-agents.
  - **`order_tracker`**: Specialized sub-agent with `OrderLookupOutput` schema; dynamically loads `order-tracking` skill.
  - **`refund_specialist`**: Specialized sub-agent with `RefundOutput` schema; dynamically loads `refund-policy` skill.
  - **Dynamic CA Mount**: Automatically checks for `app/gateway_ca.crt` and injects it into Python/gRPC trust stores to support TLS inspection.
- **Local Run**:
  ```bash
  cd "1 - multi agent ADK app/order-assistant"
  agents-cli run "Check order ORD-102 and payment card."
  ```

---

### Stage 2: Zero-Trust Cloud Run Deployment
- **Folder**: [`2 - deploy MCP on Cloud Run/`](./2%20-%20deploy%20MCP%20on%20Cloud%20Run)
- **Objective**: Deploy the FastMCP server from Stage 0 to Google Cloud Run with **`--no-allow-unauthenticated`**. Public internet access is completely blocked; invocation requires IAM authentication.
- **Deployment**:
  ```bash
  cd "2 - deploy MCP on Cloud Run"
  ./deploy.sh
  ```

---

### Stage 3: Setup Egress Agent Gateway & Agent Registry
- **Folder**: [`3 - setup Agent Gateway and Registry/`](./3%20-%20setup%20Agent%20Gateway%20and%20Registry)
- **Objective**: Provision the **Google-Managed Egress Agent Gateway** (`order-agent-gateway`) in `AGENT_TO_ANYWHERE` mode and register the private Cloud Run MCP server (`order-mcp-server`) in the Agent Registry.
- **Deployment**:
  ```bash
  cd "3 - setup Agent Gateway and Registry"
  ./deploy.sh
  ```

---

### Stage 4: Deploy to Vertex AI Agent Engine
- **Folder**: [`4 - deploy Agent on Agent Engine/`](./4%20-%20deploy%20Agent%20on%20Agent%20Engine)
- **Objective**:
  1. Exports the gateway's TLS inspection root CA and saves it to `app/gateway_ca.crt`.
  2. Deploys the multi-agent app to Vertex AI Agent Engine with **`--agent-identity`**.
  3. Binds the Reasoning Engine to the egress gateway (`spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig.agentGateway`).
  4. Dynamically grants `roles/run.invoker` strictly to the unique SPIFFE Agent Identity principal.
- **Deployment**:
  ```bash
  cd "4 - deploy Agent on Agent Engine"
  ./deploy.sh
  ```

---

### Stage 5: Egress Model Armor SDP & MCP Tool Governance
- **Folder**: [`5 - policy enforcement and tool governance/`](./5%20-%20policy%20enforcement%20and%20tool%20governance)
- **Objective**: Apply dual-layer security policies directly on the Egress Agent Gateway:
  1. **Layer 1: Sensitive Data Protection (SDP)** on `CONTENT_AUTHZ`:
     - Creates Cloud DLP `card-inspect-template` (`CREDIT_CARD_NUMBER`) and `card-deidentify-template` (`[CREDIT_CARD_NUMBER]`).
     - Attaches Model Armor response template via `AuthzExtension` to redact sensitive card numbers from tool outputs.
  2. **Layer 2: MCP Tool Denial Policy** on `REQUEST_AUTHZ`:
     - Creates an authorization policy denying `tools/call` for `process_refund`, preventing the agent from executing refunds.
- **Deployment**:
  ```bash
  cd "5 - policy enforcement and tool governance"
  ./deploy.sh
  ```
- **Cleanup / Policy Rollback**:
  ```bash
  ./restore_baseline_policy.sh
  ```

---

## 🔑 Certificate Lifecycle Across Sequential Stages

A common architectural question when deploying this repository sequentially is:
> *"The scripts are executed in sequence (Stage 0 -> Stage 1 -> Stage 2 -> Stage 3 -> Stage 4 -> Stage 5). How does Stage 1 have the certificate of the Agent Gateway if the gateway isn't created until Stage 3, and policies aren't applied until Stage 5?"*

The repository handles this cleanly via a **decoupled, multi-phase certificate lifecycle**:

```
Stage 1 (Local Dev)        Stage 3 (Gateway Setup)      Stage 4 (Agent Deploy)       Stage 5 (Policy Enforcement)
┌──────────────────────┐   ┌────────────────────────┐   ┌────────────────────────┐   ┌───────────────────────────┐
│ • Local machine      │   │ • Gateway provisioned  │   │ • gateway_ca.crt baked │   │ • Model Armor SDP & Tool  │
│ • No gateway exists  │──►│ • GCP generates CA     │──►│   into container image │──►│   Denial applied          │
│ • agent.py skips cert│   │ • Script exports CA to │   │ • Reasoning Engine     │   │ • Gateway performs TLS    │
│   check gracefully   │   │   Stage 1 app dir      │   │   trusts Gateway CA    │   │   inspection seamlessly   │
└──────────────────────┘   └────────────────────────┘   └────────────────────────┘   └───────────────────────────┘
```

1. **Stage 1 (Local Development — No Cert Needed)**:
   - When developing locally on your laptop, the agent connects directly to the local or remote MCP server.
   - In [`order-assistant/app/agent.py`](./1%20-%20multi%20agent%20ADK%20app/order-assistant/app/agent.py), the certificate loader tests if `gateway_ca.crt` exists. Because it does not exist yet, **it skips CA injection without error**.
2. **Stage 3 (Gateway Provisioning — CA Generated)**:
   - In Stage 3, `gcloud network-services agent-gateways import` provisions the Google-Managed Egress Gateway.
   - Google Cloud automatically generates the TLS inspection root CA (`agentGatewayCard.rootCertificates`).
   - `3 - setup Agent Gateway and Registry/deploy.sh` exports this certificate and writes it to:
     ```
     1 - multi agent ADK app/order-assistant/app/gateway_ca.crt
     ```
3. **Stage 4 (Cloud Deployment — CA Baked into Container)**:
   - When deploying to Vertex AI Agent Engine, `4 - deploy Agent on Agent Engine/deploy.sh` verifies `gateway_ca.crt` is present.
   - When `agents-cli deploy` builds and pushes the Reasoning Engine container image, `gateway_ca.crt` is bundled inside the container.
   - At runtime inside Google Cloud, `agent.py` loads `gateway_ca.crt` into `certifi`, `REQUESTS_CA_BUNDLE`, `SSL_CERT_FILE`, and `GRPC_DEFAULT_SSL_ROOTS_FILE_PATH`.
   - The Reasoning Engine is now bound to the Egress Gateway (`spec.deploymentSpec.agentGatewayConfig`).
4. **Stage 5 (Policy Enforcement — Transparent Inspection)**:
   - When Stage 5 attaches Model Armor SDP (`CONTENT_AUTHZ`) and MCP Tool Denial (`REQUEST_AUTHZ`), the gateway performs outbound TLS inspection.
   - Because the Reasoning Engine was already deployed in Stage 4 with the gateway's CA in its trust store, all outbound MCP tool calls are inspected and transformed without any TLS handshake or `self-signed certificate in chain` errors.

---

## 🧪 Live Verification & Proof of Enforcement

Both policies can be verified live using streaming queries against the deployed Vertex AI Reasoning Engine:

### Test 1: Allowed Tool with Sensitive Data Redaction
**Query**:
> *"Can you check the status and payment card of order ORD-102?"*

**Execution Trace**:
1. `order_tracker` calls `get_order(order_id="ORD-102")` through the Agent Gateway.
2. FastMCP server returns raw data:
   ```json
   {
     "order_id": "ORD-102",
     "item": "Mechanical Keyboard",
     "status": "delayed",
     "card_number": "4532-1234-5678-9014"
   }
   ```
3. Model Armor SDP intercepts the response body on egress and transforms the card number.
4. **Final Model Response Delivered**:
   ```markdown
   Hello! I'd be happy to check on that for you.

   I've looked up order ORD-102 and here are the details:
   • Item: Mechanical Keyboard
   • Status: The order is currently delayed.
   • Payment Card: [CREDIT_CARD_NUMBER]
   ```
✅ **Sensitive payment card redacted before reaching the user!**

---

### Test 2: Blocked Tool Call (MCP Policy Denial)
**Query**:
> *"Can you process a refund for order ORD-102 because the package was damaged?"*

**Execution Trace**:
1. Coordinator delegates to `refund_specialist`, which invokes MCP tool `process_refund(order_id="ORD-102")`.
2. Agent Gateway inspects the MCP JSON-RPC frame (`tools/call` for `process_refund`).
3. Matched by policy `order-agent-gateway-deny-refund` (`REQUEST_AUTHZ` DENY).
4. **Gateway drops the request with HTTP 403 Forbidden**:
   ```text
   httpx.HTTPStatusError: Client error '403 Forbidden' for url 'https://order-mcp-server-...run.app/messages/?session_id=...'
   ERROR:mcp.client.sse:Error in post_writer
   ```
✅ **High-risk tool call blocked at the gateway perimeter!**

---

## 🚀 Prerequisites & Portability Guide

This entire repository is designed with **zero hardcoded project IDs, instance numbers, or organization IDs**. You can deploy it directly into your own Google Cloud project.

### Prerequisites

1. **Google Cloud Project** with billing enabled.
2. **Tools Installed**:
   - `gcloud` CLI authenticated (`gcloud auth login` and `gcloud auth application-default login`)
   - `uv` (fast Python package manager)
   - `google-agents-cli` (`uv tool install google-agents-cli`)
   - `jq` and `curl`

### Running in Your Own Project

Every `deploy.sh` script automatically detects your active `gcloud` configuration project:

```bash
# 1. Clone the repository
git clone <your-repo-url>
cd agent-gateway-advanced

# 2. Deploy Stage 2: Cloud Run FastMCP Server
cd "2 - deploy MCP on Cloud Run"
./deploy.sh

# 3. Deploy Stage 3: Egress Agent Gateway & Agent Registry
cd "../3 - setup Agent Gateway and Registry"
./deploy.sh

# 4. Deploy Stage 4: Vertex AI Agent Engine with SPIFFE Identity
cd "../4 - deploy Agent on Agent Engine"
./deploy.sh

# 5. Deploy Stage 5: Model Armor SDP Redaction & MCP Tool Governance
cd "../5 - policy enforcement and tool governance"
./deploy.sh
```

---

## 📄 License & Attribution

Licensed under the Apache License, Version 2.0. See [LICENSE](LICENSE) for details.
Built with Google Agent Development Kit (ADK 2.0) and Google Cloud Gemini Enterprise Agent Platform.
