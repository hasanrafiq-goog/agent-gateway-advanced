#!/usr/bin/env bash
set -e

# ==============================================================================
# Stage 3: Setup Egress Agent Gateway and Agent Registry (gcloud CLI)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================================="
echo " Stage 3: Setup Egress Agent Gateway (AGENT_TO_ANYWHERE) & Agent Registry"
echo "=============================================================================="

# ------------------------------------------------------------------------------
# 1. Gather & Confirm Inputs from User
# ------------------------------------------------------------------------------
if ! command -v gcloud &> /dev/null; then
  echo "❌ Error: 'gcloud' CLI is required. Please install and authenticate first."
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

if [ -z "$MCP_SSE_URL" ]; then
  echo "❌ Error: Cloud Run MCP SSE URL is required (e.g. from Stage 2)."
  exit 1
fi

echo ""
echo "🚀 Configuration Summary:"
echo "   - Project ID          : $PROJECT_ID"
echo "   - Region              : $REGION"
echo "   - Egress Gateway Name : $GATEWAY_NAME (AGENT_TO_ANYWHERE)"
echo "   - MCP SSE URL         : $MCP_SSE_URL"
echo ""

# ------------------------------------------------------------------------------
# 2. Enable Required GCP APIs for Gateway and Registry
# ------------------------------------------------------------------------------
echo "==> [1/4] Enabling required APIs (networkservices, agentregistry, aiplatform, serviceextensions, networksecurity, modelarmor)..."
gcloud services enable \
  networkservices.googleapis.com \
  agentregistry.googleapis.com \
  aiplatform.googleapis.com \
  serviceextensions.googleapis.com \
  networksecurity.googleapis.com \
  modelarmor.googleapis.com \
  --project="$PROJECT_ID"

PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format="value(projectNumber)")
DEP_SERVICE_ACCOUNT="service-${PROJECT_NUMBER}@gcp-sa-dep.iam.gserviceaccount.com"

# Grant DEP service agent baseline permissions for gateway operations
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
  --member="serviceAccount:${DEP_SERVICE_ACCOUNT}" \
  --role="roles/serviceusage.serviceUsageConsumer" \
  --quiet > /dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# 3. Create / Import the Egress Agent Gateway (AGENT_TO_ANYWHERE)
# ------------------------------------------------------------------------------
echo "==> [2/4] Provisioning Egress Agent Gateway ($GATEWAY_NAME)..."
TMP_GW_YAML=$(mktemp)
cat > "$TMP_GW_YAML" << EOF
name: ${GATEWAY_NAME}
protocols:
  - MCP
googleManaged:
  governedAccessPath: AGENT_TO_ANYWHERE
registries:
  - "//agentregistry.googleapis.com/projects/${PROJECT_ID}/locations/${REGION}"
EOF

gcloud network-services agent-gateways import "$GATEWAY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --source="$TMP_GW_YAML" \
  --quiet || echo "Egress Gateway import completed or already exists, continuing..."

rm -f "$TMP_GW_YAML"

# ------------------------------------------------------------------------------
# 4. Register Cloud Run MCP Server and Platform APIs in Agent Registry
# ------------------------------------------------------------------------------
echo "==> [3/4] Registering Cloud Run MCP Server in Agent Registry..."
gcloud agent-registry services create order-mcp-server \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --display-name="Order and Refund MCP Server" \
  --description="FastMCP Server providing get_order and process_refund tools" \
  --mcp-server-spec-type=no-spec \
  --interfaces="url=${MCP_SSE_URL},protocolBinding=jsonrpc" \
  --quiet || echo "MCP Service already registered in Agent Registry, continuing..."

# ------------------------------------------------------------------------------
# 5. Display Gateway Card & Certificate Details
# ------------------------------------------------------------------------------
echo "==> [4/4] Fetching Egress Agent Gateway details and Root Certificates..."
echo ""
GW_INFO=$(gcloud network-services agent-gateways describe "$GATEWAY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="json" 2>/dev/null || echo "{}")

# Export root CA certificates to Stage 1 app directory for future deployment
GW_CERT=$(gcloud network-services agent-gateways describe "$GATEWAY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format="value[delimiter=\\n](agentGatewayCard.rootCertificates)" 2>/dev/null || echo "")

AGENT_APP_DIR="$SCRIPT_DIR/../1 - multi agent ADK app/order-assistant/app"
if [ -n "$GW_CERT" ] && [ -d "$AGENT_APP_DIR" ]; then
  echo "$GW_CERT" > "$AGENT_APP_DIR/gateway_ca.crt"
  echo "   ✅ Exported Gateway Root CA to: 1 - multi agent ADK app/order-assistant/app/gateway_ca.crt"
fi

echo "=============================================================================="
echo "✅ Stage 3 Setup Complete!"
echo "   - Egress Gateway (Outbound) : projects/$PROJECT_ID/locations/$REGION/agentGateways/$GATEWAY_NAME"
echo "   - Mode                      : AGENT_TO_ANYWHERE (Google Managed)"
echo "   - Registered MCP Server     : order-mcp-server (${MCP_SSE_URL})"
if [ -n "$GW_CARD" ]; then
  echo "   - Gateway Root Certificates : Provisioned & saved to Stage 1 app/gateway_ca.crt"
fi
echo "=============================================================================="
echo ""
