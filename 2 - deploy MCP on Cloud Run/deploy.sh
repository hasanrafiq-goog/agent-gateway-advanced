#!/usr/bin/env bash
set -e

# ==============================================================================
# Stage 2: Deploy FastMCP Server to Google Cloud Run (gcloud CLI)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================================="
echo " Stage 2: Deploying FastMCP Order Server to Google Cloud Run via gcloud CLI"
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

read -rp "Enter Cloud Run Service Name [order-mcp-server]: " INPUT_SERVICE_NAME
SERVICE_NAME="${INPUT_SERVICE_NAME:-order-mcp-server}"

echo ""
echo "🚀 Deployment Configuration:"
echo "   - Project ID    : $PROJECT_ID"
echo "   - Region        : $REGION"
echo "   - Service Name  : $SERVICE_NAME"
echo "   - Source Folder : ../0 - setup MCP server"
echo ""

# ------------------------------------------------------------------------------
# 2. Enable Required GCP APIs
# ------------------------------------------------------------------------------
echo "==> [1/3] Enabling required Google Cloud APIs..."
gcloud services enable \
  run.googleapis.com \
  cloudbuild.googleapis.com \
  artifactregistry.googleapis.com \
  --project="$PROJECT_ID"

# ------------------------------------------------------------------------------
# 3. Deploy MCP Server directly to Cloud Run from Source (Private IAM Enforced)
# ------------------------------------------------------------------------------
echo "==> [2/3] Building container and deploying to Cloud Run (Private / No unauthenticated)..."
gcloud run deploy "$SERVICE_NAME" \
  --source="../0 - setup MCP server" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --port=8080 \
  --no-allow-unauthenticated \
  --min-instances=0 \
  --max-instances=5 \
  --memory=512Mi \
  --cpu=1 \
  --quiet

# ------------------------------------------------------------------------------
# 4. Fetch Live Service URL
# ------------------------------------------------------------------------------
echo "==> [3/3] Fetching live service URL..."
SERVICE_URL=$(gcloud run services describe "$SERVICE_NAME" \
  --project="$PROJECT_ID" \
  --region="$REGION" \
  --format="value(status.url)")

MCP_SSE_URL="${SERVICE_URL}/sse"

echo ""
echo "=============================================================================="
echo "✅ Cloud Run MCP Server successfully deployed (Private / Zero-Trust)!"
echo "   Base URL : $SERVICE_URL"
echo "   SSE URL  : $MCP_SSE_URL"
echo "=============================================================================="
echo ""

echo "🔒 Security Configuration:"
echo "   - Authentication : Enforced (Zero-Trust Private, --no-allow-unauthenticated)"
echo "   - Authorized IAM : Invoker permission will be bound strictly to the"
echo "                      Reasoning Engine Agent Identity in Stage 4."
echo "   - Public Access  : BLOCKED"
echo ""
