#!/usr/bin/env bash
set -e

# ==============================================================================
# Stage 4: Deploy ADK Multi-Agent App to Agent Engine with Agent Gateway Egress
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================================="
echo " Stage 4: Deploying ADK Multi-Agent App to Vertex AI Agent Engine"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Gather & Confirm Inputs from User
# ------------------------------------------------------------------------------
if ! command -v gcloud &> /dev/null; then
  echo "❌ Error: 'gcloud' CLI is required. Please install and authenticate first."
  exit 1
fi

if ! command -v agents-cli &> /dev/null; then
  echo "❌ Error: 'agents-cli' is required. Run 'uv tool install google-agents-cli'."
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

read -rp "Enter Agent Gateway Name [order-agent-gateway]: " INPUT_GW_NAME
GATEWAY_NAME="${INPUT_GW_NAME:-order-agent-gateway}"

# Detect live Cloud Run MCP URL from Stage 2 if available
DETECTED_MCP_URL=$(gcloud run services describe order-mcp-server --region="$REGION" --project="$PROJECT_ID" --format="value(status.url)" 2>/dev/null || echo "")
if [ -n "$DETECTED_MCP_URL" ]; then
  DEFAULT_SSE_URL="${DETECTED_MCP_URL}/sse"
else
  DEFAULT_SSE_URL=""
fi

read -rp "Enter Live Cloud Run MCP SSE URL [${DEFAULT_SSE_URL}]: " INPUT_MCP_URL
MCP_SSE_URL="${INPUT_MCP_URL:-$DEFAULT_SSE_URL}"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)

echo ""
echo "🚀 Deployment Configuration:"
echo "   - Project ID     : $PROJECT_ID ($PROJECT_NUMBER)"
echo "   - Region         : $REGION"
echo "   - Agent Gateway  : projects/$PROJECT_ID/locations/$REGION/agentGateways/$GATEWAY_NAME"
echo "   - MCP Server URL : $MCP_SSE_URL"
echo ""

# ------------------------------------------------------------------------------
# 2. Update .env in Stage 1 with Live Project, Location & MCP Server URL
# ------------------------------------------------------------------------------
echo "==> [1/6] Updating Stage 1 .env with live Project, Global Location & MCP URL..."
AGENT_DIR="$SCRIPT_DIR/../1 - multi agent ADK app/order-assistant"

if [ ! -d "$AGENT_DIR" ]; then
  echo "❌ Error: Agent directory '$AGENT_DIR' not found."
  exit 1
fi

if [ ! -f "$AGENT_DIR/.env" ] && [ -f "$AGENT_DIR/.env.example" ]; then
  cp "$AGENT_DIR/.env.example" "$AGENT_DIR/.env"
fi

cat > "$AGENT_DIR/.env" << EOF
GOOGLE_GENAI_USE_VERTEXAI=true
GOOGLE_CLOUD_PROJECT=${PROJECT_ID}
GOOGLE_CLOUD_LOCATION=global
MCP_SERVER_URL=${MCP_SSE_URL}
EOF
echo "   ✅ Configured .env with project: $PROJECT_ID, location: global, MCP: $MCP_SSE_URL"


# ------------------------------------------------------------------------------
# 3. Enhance Agent with Agent Runtime deployment target (if not already set)
# ------------------------------------------------------------------------------
echo "==> [2/6] Ensuring Agent Runtime deployment configuration..."
cd "$AGENT_DIR"

if ! grep -q "deployment_target: agent_runtime" agents-cli-manifest.yaml 2>/dev/null; then
  echo "Enhancing project for agent_runtime deployment target..."
  agents-cli scaffold enhance . --deployment-target agent_runtime || true
fi

# ------------------------------------------------------------------------------
# 3b. Export Agent Gateway Root CA for Container Bundling & Egress TLS Inspection
# ------------------------------------------------------------------------------
echo "==> Exporting Agent Gateway root certificates for egress TLS inspection..."
GW_CERT=$(gcloud network-services agent-gateways describe "$GATEWAY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="value[delimiter=\\n](agentGatewayCard.rootCertificates)" 2>/dev/null || echo "")

if [ -n "$GW_CERT" ]; then
  echo "$GW_CERT" > "$AGENT_DIR/app/gateway_ca.crt"
  echo "   ✅ Saved Gateway Root CA to app/gateway_ca.crt for container deployment."
fi

# ------------------------------------------------------------------------------
# 4. Deploy Agent to Vertex AI Agent Engine with Agent Identity
# ------------------------------------------------------------------------------
echo "==> [3/6] Deploying ADK Agent to Vertex AI Agent Engine (with --agent-identity)..."
agents-cli deploy \
  --project "$PROJECT_ID" \
  --region "$REGION" \
  --agent-identity \
  --update-env-vars "MCP_SERVER_URL=${MCP_SSE_URL}" \
  --no-confirm-project

# Extract the deployed reasoning engine resource ID from deployment_metadata.json
if [ -f "deployment_metadata.json" ] && (grep -q "$PROJECT_ID" deployment_metadata.json || grep -q "$PROJECT_NUMBER" deployment_metadata.json); then
  REASONING_ENGINE_FULL_ID=$(grep '"remote_agent_runtime_id"' deployment_metadata.json | cut -d'"' -f4)
  RESOURCE_ID=$(basename "$REASONING_ENGINE_FULL_ID")
else
  echo "Fetching latest reasoning engine ID from GCP..."
  RE_LIST=$(curl -s -H "Authorization: Bearer $TOKEN" \
    -H "x-goog-user-project: ${PROJECT_ID}" \
    "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines")
  REASONING_ENGINE_FULL_ID=$(echo "$RE_LIST" | jq -r '.reasoningEngines[0].name // empty')
  RESOURCE_ID=$(basename "$REASONING_ENGINE_FULL_ID")
fi

echo "✅ Reasoning Engine created: $REASONING_ENGINE_FULL_ID (ID: $RESOURCE_ID)"

# ------------------------------------------------------------------------------
# 5. Register Deployed Agent in Agent Registry
# ------------------------------------------------------------------------------
echo "==> [4/6] Registering deployed Reasoning Engine in Agent Registry..."
gcloud agent-registry services create order-assistant \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --display-name="order-assistant" \
  --description="Order Assistant ADK Agent" \
  --agent-spec-type=no-spec \
  --interfaces="url=https://${REGION}-aiplatform.googleapis.com/v1/${REASONING_ENGINE_FULL_ID},protocolBinding=http-json" \
  --quiet || echo "Agent already registered in Agent Registry, continuing..."

# ------------------------------------------------------------------------------
# 6. Grant Baseline IAM Roles for SPIFFE Agent Identity & Platform Services
# ------------------------------------------------------------------------------
echo "==> [5/6] Granting baseline IAM roles for SPIFFE Agent Identity & Platform SAs..."
ORG_ID=$(gcloud projects get-ancestors "$PROJECT_ID" --format="value(id)" | tail -n 1)
RE_AGENT_ID_SET="principalSet://agents.global.org-${ORG_ID}.system.id.goog/attribute.platformContainer/aiplatform/projects/${PROJECT_NUMBER}"

EFFECTIVE_IDENTITY=$(curl -s -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "https://${REGION}-aiplatform.googleapis.com/v1/projects/${PROJECT_ID}/locations/${REGION}/reasoningEngines/${RESOURCE_ID}" | jq -r '.spec.effectiveIdentity // empty' 2>/dev/null || echo "")

if [ -n "$EFFECTIVE_IDENTITY" ]; then
  AGENT_IDENTITY_PRINCIPAL="principal://${EFFECTIVE_IDENTITY}"
else
  AGENT_IDENTITY_PRINCIPAL="principal://agents.global.org-${ORG_ID}.system.id.goog/resources/aiplatform/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RESOURCE_ID}"
fi

echo "Binding roles/run.invoker to SPIFFE Agent Identity ($AGENT_IDENTITY_PRINCIPAL)..."
gcloud run services add-iam-policy-binding "order-mcp-server" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="$AGENT_IDENTITY_PRINCIPAL" \
  --role="roles/run.invoker" \
  --quiet || true

DISCOVERY_ENGINE_SA="serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-discoveryengine.iam.gserviceaccount.com"
gcloud run services add-iam-policy-binding "order-mcp-server" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --member="$DISCOVERY_ENGINE_SA" \
  --role="roles/run.invoker" \
  --quiet || true

# Grant Agent Identity Baseline Roles
echo "Granting baseline IAM roles to Agent Identity..."
for ROLE in \
  "roles/mcp.toolUser" \
  "roles/aiplatform.user" \
  "roles/aiplatform.agentDefaultAccess" \
  "roles/agentregistry.viewer" \
  "roles/logging.logWriter" \
  "roles/monitoring.metricWriter" \
  "roles/browser"; do
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$AGENT_IDENTITY_PRINCIPAL" \
    --role="$ROLE" \
    --quiet || true
  gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="$RE_AGENT_ID_SET" \
    --role="$ROLE" \
    --quiet || true
done

# ------------------------------------------------------------------------------
# 7. Configure IAP Egress Permission on Agent Registry for SPIFFE Agent Identity
# ------------------------------------------------------------------------------
echo "==> [6/6] Configuring IAP egress policy on Agent Registry (roles/iap.egressor)..."
TMP_IAP_JSON=$(mktemp)
cat > "$TMP_IAP_JSON" << EOF
{
  "bindings": [
    {
      "role": "roles/iap.egressor",
      "members": [
        "${AGENT_IDENTITY_PRINCIPAL}",
        "${RE_AGENT_ID_SET}",
        "${DISCOVERY_ENGINE_SA}",
        "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com",
        "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
      ]
    },
    {
      "role": "roles/iap.httpsResourceAccessor",
      "members": [
        "${AGENT_IDENTITY_PRINCIPAL}",
        "${RE_AGENT_ID_SET}",
        "${DISCOVERY_ENGINE_SA}",
        "serviceAccount:service-${PROJECT_NUMBER}@gcp-sa-aiplatform-re.iam.gserviceaccount.com",
        "serviceAccount:${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"
      ]
    }
  ]
}
EOF

gcloud beta iap web set-iam-policy "$TMP_IAP_JSON" \
  --resource-type=agent-registry \
  --region="$REGION" \
  --project="$PROJECT_ID" \
  --quiet || true

# ------------------------------------------------------------------------------
# 8. Associate Reasoning Engine with Egress Agent Gateway
# ------------------------------------------------------------------------------
echo "==> [7/7] Associating Reasoning Engine with Egress Agent Gateway ($GATEWAY_NAME)..."
GATEWAY_RESOURCE="projects/${PROJECT_ID}/locations/${REGION}/agentGateways/${GATEWAY_NAME}"
curl -s -X PATCH \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json; charset=utf-8" \
  -d '{
    "spec": {
      "deploymentSpec": {
        "agentGatewayConfig": {
          "agentToAnywhereConfig": {
            "agentGateway": "'"${GATEWAY_RESOURCE}"'"
          }
        }
      }
    }
  }' \
  "https://${REGION}-aiplatform.googleapis.com/v1/${REASONING_ENGINE_FULL_ID}?updateMask=spec.deploymentSpec.agentGatewayConfig" > /dev/null
echo "   ✅ Reasoning Engine successfully bound to Egress Gateway: $GATEWAY_RESOURCE"

echo ""
echo "=============================================================================="
echo "🎉 Stage 4 Deployment Complete!"
echo "   - Reasoning Engine URL : https://${REGION}-aiplatform.googleapis.com/v1/$REASONING_ENGINE_FULL_ID"
echo "   - Gateway Egress       : $GATEWAY_NAME (Governing outbound MCP & Platform traffic)"
echo "=============================================================================="
echo ""

echo "==> Testing live deployed Reasoning Engine remotely via ADK streaming mode..."
agents-cli run --url "https://${REGION}-aiplatform.googleapis.com/v1/$REASONING_ENGINE_FULL_ID" --mode adk "Can you check the status and payment card of order ORD-102?"

echo ""
echo "💡 To query this deployed agent anytime from your terminal:"
echo "   agents-cli run --url \"https://${REGION}-aiplatform.googleapis.com/v1/$REASONING_ENGINE_FULL_ID\" --mode adk \"<your prompt>\""
echo ""
