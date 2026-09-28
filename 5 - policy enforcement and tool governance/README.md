# Stage 5: Egress Policy Enforcement with Model Armor SDP & MCP Tool Governance

## Overview

In **Stage 5**, we enforce two layers of policy governance on outbound (Egress) agent communications using **Google Cloud Agent Gateway** in `AGENT_TO_ANYWHERE` mode:

1. **Model Armor & Sensitive Data Protection (SDP) Redaction (`CONTENT_AUTHZ`)**:
   - Inspects and redacts sensitive data (Credit Card Numbers) returning from tool payloads before reaching the agent.
2. **MCP Protocol-Level Tool Denial Policy (`REQUEST_AUTHZ`)**:
   - Parses the Model Context Protocol (MCP) JSON-RPC payload and blocks unauthorized tool calls (such as `process_refund`) directly at the gateway with `403 Forbidden`.

```
                    ┌─────────────────────────────────────────────────────────┐
                    │               Model Armor & DLP (SDP)                   │
                    │  - Inspect Template (CREDIT_CARD_NUMBER)                │
                    │  - De-identify Template ([CREDIT_CARD_NUMBER])          │
                    │  - Content Guardrails (RAI, Injection, Malicious URI)   │
                    └──────────────────────────┬──────────────────────────────┘
                                               │ (Service Extension Callout)
                                               ▼
 [User] ──► [Reasoning Engine] ──( Outbound Call )──► [Agent Gateway (Egress)]
                 │                                              │
                 │              ┌───────────────────────────────┴───────────────────────────────┐
                 │              │                                                               │
                 │              ▼ [tools/call: process_refund]                                  ▼ [tools/call: get_order]
                 │        [DENY POLICY]                                                   [ALLOWED TO RUN]
                 │        403 Forbidden (Blocked by AGW)                                        │
                 │                                                                              ▼
                 │                                                                     [FastMCP Server]
                 │                                                                      Returns order data +
                 │                                                                      raw card number
                 │                                                                              │
                 │                                                                              ▼
                 │                                                                     [Model Armor SDP Masking]
                 │                                                                      Replaces card with
                 │                                                                      [CREDIT_CARD_NUMBER]
                 │                                                                              │
                 ▼                                                                              ▼
      [Refund Blocked Message] <───────────────────────────────────────────────── [Masked Tool Data]
```

---

## 🛠️ Gateway Policy Architecture

### 1. Model Armor Content Guardrail (`CONTENT_AUTHZ`)

Attached via `AuthzExtension` pointing to `modelarmor.<REGION>.rep.googleapis.com` with request and response templates:

```yaml
name: order-agent-gateway-authz-policy-modar
target:
  resources:
    - "projects/PROJECT_ID/locations/<REGION>/agentGateways/<GATEWAY_NAME>"
policyProfile: CONTENT_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
      - "projects/PROJECT_ID/locations/<REGION>/authzExtensions/<EXTENSION_NAME>"
httpRules:
  - to:
      operations: [ { "paths": [ { "prefix": "/" } ] } ]
    when: >
      request.headers['content-type'] == 'application/json' ||
      request.headers['content-type'].startsWith('text/')
```

### 2. MCP Tool Denial Policy (`REQUEST_AUTHZ`)

Enforces tool-level access control based on MCP method parameters directly in the Agent Gateway:

```yaml
name: order-agent-gateway-deny-refund
target:
  resources:
    - "projects/PROJECT_ID/locations/<REGION>/agentGateways/<GATEWAY_NAME>"
policyProfile: REQUEST_AUTHZ
action: DENY
httpRules:
  - to:
      operations:
        - mcp:
            methods:
              - name: "tools/call"
                params:
                  - exact: "process_refund"
```

---

## 🔐 IAM Permissions

- **DEP (Service Extension) Service Agent** (`service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com`):
  - `roles/modelarmor.calloutUser`
  - `roles/modelarmor.user`
  - `roles/serviceusage.serviceUsageConsumer`
  - `roles/dlp.user`
- **Model Armor Service Agent** (`service-${PROJECT_NUMBER}@gcp-sa-modelarmor.iam.gserviceaccount.com`):
  - `roles/dlp.user`

---

## 🚀 Deployment & Verification

Run the automated deployment script:

```bash
chmod +x deploy.sh
./deploy.sh
```

The script will:
1. Enable APIs & grant IAM roles to Gateway DEP and Model Armor service agents.
2. Provision Cloud DLP inspect (`card-inspect-template`) and de-identify (`card-deidentify-template`) templates.
3. Provision Model Armor request and response templates with SDP de-identification configured.
4. Import the `AuthzExtension` pointing to `modelarmor.us-central1.rep.googleapis.com`.
5. Import the `CONTENT_AUTHZ` `AuthzPolicy` targeting `order-agent-gateway`.
6. Import the `REQUEST_AUTHZ` `AuthzPolicy` denying `process_refund`.
7. Verify Reasoning Engine binding to the egress gateway.
8. Run live verification tests:
   - Allowed tool (`get_order`) with sensitive card number redaction.
   - Denied tool (`process_refund`) blocked with `403 Forbidden` by Agent Gateway.

### Cleanup

To remove the security policies and templates:

```bash
chmod +x restore_baseline_policy.sh
./restore_baseline_policy.sh
```
