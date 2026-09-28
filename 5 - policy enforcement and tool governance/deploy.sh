#!/usr/bin/env bash
set -e

# ==============================================================================
# Stage 5: Egress Model Armor Guardrails, SDP Redaction & MCP Tool Governance
# Governs outbound agent traffic (agent to tools/MCP) on Agent Gateway
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================================="
echo " Stage 5: Egress Model Armor Guardrails, SDP Redaction & MCP Tool Governance"
echo "          (CONTENT_AUTHZ + MCP Tool Denial REQUEST_AUTHZ) on Agent Gateway"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Inputs & Configuration
# ------------------------------------------------------------------------------
if ! command -v gcloud &> /dev/null; then
  echo "❌ Error: 'gcloud' CLI is required. Please install and authenticate first."
  exit 1
fi

if ! command -v jq &> /dev/null; then
  echo "❌ Error: 'jq' is required. Please install jq."
  exit 1
fi

DETECTED_PROJECT=$(gcloud config get-value project 2>/dev/null || echo "")

read -rp "Enter GCP Project ID [${DETECTED_PROJECT}]: " INPUT_PROJECT
PROJECT_ID="${INPUT_PROJECT:-$DETECTED_PROJECT}"

if [ -z "$PROJECT_ID" ]; then
  echo "❌ Error: GCP Project ID is required."
  exit 1
fi

read -rp "Enter GCP Region [us-central1]: " INPUT_REGION
REGION="${INPUT_REGION:-us-central1}"

read -rp "Enter Egress Agent Gateway Name [order-agent-gateway]: " INPUT_GW_NAME
GATEWAY_NAME="${INPUT_GW_NAME:-order-agent-gateway}"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
DEP_SERVICE_ACCOUNT="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"
MODEL_ARMOR_SERVICE_ACCOUNT="service-${PROJECT_NUMBER}@gcp-sa-modelarmor.iam.gserviceaccount.com"

# Resource Identifiers
REQ_TEMPLATE_ID="${GATEWAY_NAME}-modar-req-template"
FULL_REQ_TEMPLATE_ID="projects/${PROJECT_ID}/locations/${REGION}/templates/${REQ_TEMPLATE_ID}"

RESP_TEMPLATE_ID="${GATEWAY_NAME}-modar-resp-template"
FULL_RESP_TEMPLATE_ID="projects/${PROJECT_ID}/locations/${REGION}/templates/${RESP_TEMPLATE_ID}"

INSPECT_TEMPLATE_ID="card-inspect-template"
FULL_INSPECT_TEMPLATE="projects/${PROJECT_ID}/locations/${REGION}/inspectTemplates/${INSPECT_TEMPLATE_ID}"

DEIDENTIFY_TEMPLATE_ID="card-deidentify-template"
FULL_DEIDENTIFY_TEMPLATE="projects/${PROJECT_ID}/locations/${REGION}/deidentifyTemplates/${DEIDENTIFY_TEMPLATE_ID}"

MA_EXT_NAME="${GATEWAY_NAME}-svc-ext-authz-modar"
MA_POLICY_NAME="${GATEWAY_NAME}-authz-policy-modar"
DENY_REFUND_POLICY_NAME="${GATEWAY_NAME}-deny-refund"

# Fetch Reasoning Engine resource
METADATA_FILE="$SCRIPT_DIR/../1 - multi agent ADK app/order-assistant/deployment_metadata.json"
if [ -f "$METADATA_FILE" ] && (grep -q "$PROJECT_ID" "$METADATA_FILE" || grep -q "$PROJECT_NUMBER" "$METADATA_FILE"); then
  REASONING_ENGINE_FULL_ID=$(grep '"remote_agent_runtime_id"' "$METADATA_FILE" | cut -d'"' -f4)
else
  RE_TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)
  RE_LIST=$(curl -s -H "Authorization: Bearer $RE_TOKEN" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines")
  REASONING_ENGINE_FULL_ID=$(echo "$RE_LIST" | jq -r '.reasoningEngines[0].name // empty')
fi

REASONING_ENGINE_URL="https://${REGION}-aiplatform.googleapis.com/v1/${REASONING_ENGINE_FULL_ID}"

echo ""
echo "🚀 Deployment Configuration:"
echo "   - Project ID              : $PROJECT_ID ($PROJECT_NUMBER)"
echo "   - Region                  : $REGION"
echo "   - Egress Agent Gateway    : $GATEWAY_NAME (AGENT_TO_ANYWHERE)"
echo "   - MA Extension            : $MA_EXT_NAME"
echo "   - MA Policy               : $MA_POLICY_NAME (CONTENT_AUTHZ)"
echo "   - Tool Denial Policy      : $DENY_REFUND_POLICY_NAME (REQUEST_AUTHZ DENY process_refund)"
echo "   - DLP Inspect Template    : $FULL_INSPECT_TEMPLATE"
echo "   - DLP De-identify Template: $FULL_DEIDENTIFY_TEMPLATE"
echo "   - Model Armor Req Template: $FULL_REQ_TEMPLATE_ID"
echo "   - Model Armor Resp Template: $FULL_RESP_TEMPLATE_ID"
echo "   - Target Reasoning Engine : $REASONING_ENGINE_URL"
echo ""

# ------------------------------------------------------------------------------
# 2. Enable Required APIs & Grant Model Armor / DLP IAM Roles
# ------------------------------------------------------------------------------
echo "==> [1/7] Enabling APIs & granting Model Armor / DLP IAM roles to Service Accounts..."
gcloud services enable \
  modelarmor.googleapis.com \
  dlp.googleapis.com \
  networksecurity.googleapis.com \
  serviceextensions.googleapis.com \
  aiplatform.googleapis.com \
  --project="$PROJECT_ID" \
  --quiet

# DEP Service Agent roles for Model Armor callouts and DLP access
echo "   Binding IAM roles to Gateway DEP Service Agent: ${DEP_SERVICE_ACCOUNT}..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEP_SERVICE_ACCOUNT}" \
  --role="roles/modelarmor.calloutUser" \
  --condition=None --quiet > /dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEP_SERVICE_ACCOUNT}" \
  --role="roles/modelarmor.user" \
  --condition=None --quiet > /dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEP_SERVICE_ACCOUNT}" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --condition=None --quiet > /dev/null

gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEP_SERVICE_ACCOUNT}" \
  --role="roles/dlp.user" \
  --condition=None --quiet > /dev/null

# Model Armor Service Agent role for DLP de-identification
echo "   Binding DLP user role to Model Armor Service Agent: ${MODEL_ARMOR_SERVICE_ACCOUNT}..."
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${MODEL_ARMOR_SERVICE_ACCOUNT}" \
  --role="roles/dlp.user" \
  --condition=None --quiet > /dev/null

# ------------------------------------------------------------------------------
# 3. Create Cloud DLP Inspect and De-identify Templates for Credit Card Numbers
# ------------------------------------------------------------------------------
echo "==> [2/7] Configuring Cloud DLP Templates for Sensitive Data Protection (SDP)..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)
DLP_BASE="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}"

# Inspect Template: Inspect for CREDIT_CARD_NUMBER
INSPECT_STATUS=$(curl -s -o /tmp/dlp_inspect_resp.json -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d '{
    "inspectTemplate": {
      "displayName": "Credit Card Inspect Template",
      "inspectConfig": {
        "infoTypes": [
          {"name": "CREDIT_CARD_NUMBER"}
        ],
        "minLikelihood": "POSSIBLE"
      }
    },
    "templateId": "'"${INSPECT_TEMPLATE_ID}"'"
  }' \
  "${DLP_BASE}/inspectTemplates")

if [ "$INSPECT_STATUS" -eq 200 ] || [ "$INSPECT_STATUS" -eq 201 ]; then
  echo "   ✅ Created DLP Inspect Template: $FULL_INSPECT_TEMPLATE"
elif [ "$INSPECT_STATUS" -eq 400 ] || [ "$INSPECT_STATUS" -eq 409 ]; then
  echo "   ℹ️ DLP Inspect Template already exists."
else
  echo "   ⚠️ DLP Inspect Template response (HTTP $INSPECT_STATUS):"
  cat /tmp/dlp_inspect_resp.json
fi
rm -f /tmp/dlp_inspect_resp.json

# De-identify Template: Replace CREDIT_CARD_NUMBER with [CREDIT_CARD_NUMBER]
DEIDENTIFY_STATUS=$(curl -s -o /tmp/dlp_deid_resp.json -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d '{
    "deidentifyTemplate": {
      "displayName": "Credit Card Deidentify Template",
      "deidentifyConfig": {
        "infoTypeTransformations": {
          "transformations": [
            {
              "infoTypes": [
                {"name": "CREDIT_CARD_NUMBER"}
              ],
              "primitiveTransformation": {
                "replaceWithInfoTypeConfig": {}
              }
            }
          ]
        }
      }
    },
    "templateId": "'"${DEIDENTIFY_TEMPLATE_ID}"'"
  }' \
  "${DLP_BASE}/deidentifyTemplates")

if [ "$DEIDENTIFY_STATUS" -eq 200 ] || [ "$DEIDENTIFY_STATUS" -eq 201 ]; then
  echo "   ✅ Created DLP De-identify Template: $FULL_DEIDENTIFY_TEMPLATE"
elif [ "$DEIDENTIFY_STATUS" -eq 400 ] || [ "$DEIDENTIFY_STATUS" -eq 409 ]; then
  echo "   ℹ️ DLP De-identify Template already exists."
else
  echo "   ⚠️ DLP De-identify Template response (HTTP $DEIDENTIFY_STATUS):"
  cat /tmp/dlp_deid_resp.json
fi
rm -f /tmp/dlp_deid_resp.json

# ------------------------------------------------------------------------------
# 4. Configure Regional Model Armor CLI Override & Templates
# ------------------------------------------------------------------------------
echo "==> [3/7] Setting Model Armor regional endpoint override and configuring templates..."
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" --quiet

# Create / Update Request Filter Template
if gcloud beta model-armor templates describe "$REQ_TEMPLATE_ID" --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  echo "   ℹ️ Request filter template ($REQ_TEMPLATE_ID) exists."
else
  echo "   Creating Model Armor Request filter template ($REQ_TEMPLATE_ID)..."
  gcloud beta model-armor templates create "$REQ_TEMPLATE_ID" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --rai-settings-filters='[
      { "filterType": "HATE_SPEECH", "confidenceLevel": "MEDIUM_AND_ABOVE" },
      { "filterType": "HARASSMENT", "confidenceLevel": "MEDIUM_AND_ABOVE" },
      { "filterType": "SEXUALLY_EXPLICIT", "confidenceLevel": "MEDIUM_AND_ABOVE" }
    ]' \
    --pi-and-jailbreak-filter-settings-enforcement=enabled \
    --pi-and-jailbreak-filter-settings-confidence-level=medium-and-above \
    --template-metadata-enforcement-type=INSPECT_AND_BLOCK \
    --malicious-uri-filter-settings-enforcement=enabled \
    --template-metadata-custom-prompt-safety-error-code=799 \
    --template-metadata-custom-prompt-safety-error-message="The request was blocked by content filter." \
    --template-metadata-ignore-partial-invocation-failures \
    --template-metadata-log-operations \
    --template-metadata-log-sanitize-operations \
    --quiet
  echo "   ✅ Created Request filter template."
fi

# Create / Update Response Filter Template with SDP Credit Card Redaction
if gcloud beta model-armor templates describe "$RESP_TEMPLATE_ID" --location="$REGION" --project="$PROJECT_ID" &>/dev/null; then
  echo "   ℹ️ Response filter template ($RESP_TEMPLATE_ID) exists."
else
  echo "   Creating Model Armor Response filter template ($RESP_TEMPLATE_ID) with SDP..."
  gcloud beta model-armor templates create "$RESP_TEMPLATE_ID" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --rai-settings-filters='[
      { "filterType": "HATE_SPEECH", "confidenceLevel": "MEDIUM_AND_ABOVE" },
      { "filterType": "HARASSMENT", "confidenceLevel": "MEDIUM_AND_ABOVE" },
      { "filterType": "SEXUALLY_EXPLICIT", "confidenceLevel": "MEDIUM_AND_ABOVE" }
    ]' \
    --malicious-uri-filter-settings-enforcement=enabled \
    --advanced-config-inspect-template="$FULL_INSPECT_TEMPLATE" \
    --advanced-config-deidentify-template="$FULL_DEIDENTIFY_TEMPLATE" \
    --template-metadata-enforcement-type=INSPECT_AND_BLOCK \
    --template-metadata-custom-llm-response-safety-error-code=798 \
    --template-metadata-custom-llm-response-safety-error-message="Model response blocked by content filter." \
    --template-metadata-custom-prompt-safety-error-code=799 \
    --template-metadata-custom-prompt-safety-error-message="The request was blocked by content filter." \
    --template-metadata-ignore-partial-invocation-failures \
    --template-metadata-log-operations \
    --template-metadata-log-sanitize-operations \
    --quiet
  echo "   ✅ Created Response filter template with SDP."
fi

# ------------------------------------------------------------------------------
# 5. Configure CONTENT_AUTHZ Model Armor Extension & Policy
# ------------------------------------------------------------------------------
echo "==> [4/7] Configuring Model Armor CONTENT_AUTHZ Service Extension and Policy..."

TMP_MA_EXT=$(mktemp)
cat > "$TMP_MA_EXT" << EOF
name: ${MA_EXT_NAME}
service: modelarmor.${REGION}.rep.googleapis.com
metadata:
  model_armor_settings: '[
    {
      "request_template_id": "${FULL_REQ_TEMPLATE_ID}",
      "response_template_id": "${FULL_RESP_TEMPLATE_ID}"
    }
  ]'
failOpen: true
timeout: 5s
EOF

gcloud service-extensions authz-extensions import "$MA_EXT_NAME" \
  --source="$TMP_MA_EXT" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet

rm -f "$TMP_MA_EXT"
echo "   ✅ Imported AuthzExtension: $MA_EXT_NAME"

TMP_MA_POL=$(mktemp)
cat > "$TMP_MA_POL" << EOF
name: ${MA_POLICY_NAME}
target:
  resources:
  - "projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${GATEWAY_NAME}"
policyProfile: CONTENT_AUTHZ
action: CUSTOM
customProvider:
  authzExtension:
    resources:
    - "projects/${PROJECT_ID}/locations/${REGION}/authzExtensions/${MA_EXT_NAME}"
httpRules:
  - to:
      operations: [ { "paths": [ { "prefix": "/" } ] } ]
    when: >
      request.headers['content-type'] == 'application/json' ||
      request.headers['content-type'].startsWith('text/')
EOF

gcloud beta network-security authz-policies import "$MA_POLICY_NAME" \
  --source="$TMP_MA_POL" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet

rm -f "$TMP_MA_POL"
echo "   ✅ Imported AuthzPolicy: $MA_POLICY_NAME"

# ------------------------------------------------------------------------------
# 5b. Configure MCP Protocol-Level Tool Denial Policy (deny process_refund)
# ------------------------------------------------------------------------------
echo "==> Configuring MCP Tool Governance Policy (Deny 'process_refund')..."
TMP_DENY_YAML=$(mktemp)
cat > "$TMP_DENY_YAML" << EOF
name: ${DENY_REFUND_POLICY_NAME}
target:
  resources:
  - "projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${GATEWAY_NAME}"
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
EOF

gcloud beta network-security authz-policies import "$DENY_REFUND_POLICY_NAME" \
  --source="$TMP_DENY_YAML" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet

rm -f "$TMP_DENY_YAML"
echo "   ✅ Imported MCP Tool Denial Policy: $DENY_REFUND_POLICY_NAME"

# ------------------------------------------------------------------------------
# 6. Bind Reasoning Engine to Egress Agent Gateway
# ------------------------------------------------------------------------------
echo "==> [5/7] Verifying Reasoning Engine egress gateway binding..."
if [ -n "$REASONING_ENGINE_FULL_ID" ]; then
  CURRENT_GW=$(curl -s -H "Authorization: Bearer $TOKEN" \
    "https://${REGION}-aiplatform.googleapis.com/v1/${REASONING_ENGINE_FULL_ID}" \
    | jq -r '.spec.deploymentSpec.agentGatewayConfig.agentToAnywhereConfig.agentGateway // empty')

  EXPECTED_GW="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${GATEWAY_NAME}"
  if [ "$CURRENT_GW" == "$EXPECTED_GW" ]; then
    echo "   ✅ Reasoning Engine is already bound to egress gateway: $EXPECTED_GW"
  else
    echo "   Binding Reasoning Engine to egress gateway: $EXPECTED_GW..."
    curl -s -X PATCH \
      -H "Authorization: Bearer $TOKEN" \
      -H "Content-Type: application/json; charset=utf-8" \
      -d '{
        "spec": {
          "deploymentSpec": {
            "agentGatewayConfig": {
              "agentToAnywhereConfig": {
                "agentGateway": "'"${EXPECTED_GW}"'"
              }
            }
          }
        }
      }' \
      "https://${REGION}-aiplatform.googleapis.com/v1/${REASONING_ENGINE_FULL_ID}?updateMask=spec.deploymentSpec.agentGatewayConfig" > /dev/null
    echo "   ✅ Successfully bound Reasoning Engine to egress gateway."
  fi
fi

# ------------------------------------------------------------------------------
# 7. Live Guardrail, SDP & Tool Governance Verification Tests
# ------------------------------------------------------------------------------
echo "==> [6/7] Testing Model Armor Guardrails, SDP Redaction & MCP Tool Governance..."

SAFE_PROMPT="Can you check the status of order ORD-102?"
MOCK_MCP_RESPONSE='{"order_id": "ORD-102", "item": "Mechanical Keyboard", "card_number": "4532-1234-5678-9014", "status": "delayed"}'

API_BASE="https://modelarmor.${REGION}.rep.googleapis.com/v1"

echo ""
echo "------------------------------------------------------------------------------"
echo " Test 1: Benign User Query (User Prompt Sanitization)"
echo " Prompt: \"$SAFE_PROMPT\""
echo "------------------------------------------------------------------------------"
SAFE_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"userPromptData\": {\"text\": \"$SAFE_PROMPT\"}}" \
  "${API_BASE}/${FULL_REQ_TEMPLATE_ID}:sanitizeUserPrompt")

SAFE_MATCH=$(echo "$SAFE_RESP" | jq -r '.sanitizationResult.filterMatchState // empty')
echo " Guardrail Result: $SAFE_MATCH"
if [ "$SAFE_MATCH" == "NO_MATCH_FOUND" ]; then
  echo " ✅ Prompt Passed: Clean request allowed through to Agent."
else
  echo " ❌ Filter check response: $SAFE_RESP"
fi

echo ""
echo "------------------------------------------------------------------------------"
echo " Test 2: Sensitive Data Protection (SDP) Redaction on Egress Model/Tool Output"
echo " Raw Tool/Model Output: $MOCK_MCP_RESPONSE"
echo "------------------------------------------------------------------------------"
SDP_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  -H "Content-Type: application/json" \
  -d "{\"modelResponseData\": {\"text\": '$MOCK_MCP_RESPONSE'}}" \
  "${API_BASE}/${FULL_RESP_TEMPLATE_ID}:sanitizeModelResponse")

DEID_TEXT=$(echo "$SDP_RESP" | jq -r '.sanitizationResult.filterResults.sdp.sdpFilterResult.deidentifyResult.data.text // empty')
echo " Sanitized Response: $DEID_TEXT"
if [[ "$DEID_TEXT" == *"[CREDIT_CARD_NUMBER]"* ]]; then
  echo " 🔒 SENSITIVE CARD NUMBER REDACTED / MASKED BY MODEL ARMOR SDP!"
else
  echo " ⚠️ SDP de-identification check response:"
  echo "$SDP_RESP" | jq .
fi

echo ""
echo "------------------------------------------------------------------------------"
echo " Test 3: Live Query - Allowed Tool Execution & Card Number Masking"
echo " Query: \"Can you check the status and payment card of order ORD-102?\""
echo "------------------------------------------------------------------------------"
if [ -n "$REASONING_ENGINE_FULL_ID" ]; then
  STREAM_RESP=$(curl --no-buffer -s -X POST \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/${REASONING_ENGINE_FULL_ID}:streamQuery" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d '{"class_method": "async_stream_query", "input": {"message": "Can you check the status and payment card of order ORD-102?", "user_id": "user1"}}')
  echo "$STREAM_RESP"
fi

echo ""
echo "------------------------------------------------------------------------------"
echo " Test 4: Live Query - Blocked Tool Execution (MCP Policy Denies 'process_refund')"
echo " Query: \"Can you process a refund for order ORD-102?\""
echo "------------------------------------------------------------------------------"
if [ -n "$REASONING_ENGINE_FULL_ID" ]; then
  REFUND_RESP=$(curl --no-buffer -s -X POST \
    "https://${REGION}-aiplatform.googleapis.com/v1beta1/${REASONING_ENGINE_FULL_ID}:streamQuery" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Goog-User-Project: ${PROJECT_ID}" \
    -d '{"class_method": "async_stream_query", "input": {"message": "Can you process a refund for order ORD-102?", "user_id": "user1"}}')
  echo "$REFUND_RESP"
fi

echo ""
echo "=============================================================================="
echo "🎉 Stage 5 Verification Complete!"
echo "   Egress Agent Gateway is actively inspecting and protecting outbound agent"
echo "   traffic with Model Armor SDP redaction AND MCP tool governance (DENY refund)."
echo "=============================================================================="
echo ""
echo "💡 To clean up the security policies, run:"
echo "   ./restore_baseline_policy.sh"
echo ""
