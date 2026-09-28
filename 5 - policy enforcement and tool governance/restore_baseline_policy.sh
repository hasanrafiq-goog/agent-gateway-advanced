#!/usr/bin/env bash
set -e

# ==============================================================================
# Stage 5: Cleanup Model Armor Policies & Reset Baseline (restore_baseline_policy.sh)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=============================================================================="
echo " Stage 5: Cleanup Egress Model Armor Policies and SDP Templates"
echo "=============================================================================="

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

MA_POLICY_NAME="${GATEWAY_NAME}-authz-policy-modar"
MA_EXT_NAME="${GATEWAY_NAME}-svc-ext-authz-modar"
REQ_TEMPLATE_ID="${GATEWAY_NAME}-modar-req-template"
RESP_TEMPLATE_ID="${GATEWAY_NAME}-modar-resp-template"

INSPECT_TEMPLATE_ID="card-inspect-template"
DEIDENTIFY_TEMPLATE_ID="card-deidentify-template"

echo ""
echo "🧹 Cleanup Configuration:"
echo "   - Project ID            : $PROJECT_ID"
echo "   - Region                : $REGION"
echo "   - MA Policy / Ext       : $MA_POLICY_NAME / $MA_EXT_NAME"
echo "   - Model Armor Templates : $REQ_TEMPLATE_ID, $RESP_TEMPLATE_ID"
echo "   - DLP Templates         : $INSPECT_TEMPLATE_ID, $DEIDENTIFY_TEMPLATE_ID"
echo ""

# ------------------------------------------------------------------------------
# 1. Delete Authz Policies
# ------------------------------------------------------------------------------
echo "==> [1/4] Deleting Authz Policies ($MA_POLICY_NAME, ${GATEWAY_NAME}-deny-refund)..."
gcloud beta network-security authz-policies delete "$MA_POLICY_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || true

gcloud beta network-security authz-policies delete "${GATEWAY_NAME}-deny-refund" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || true

# ------------------------------------------------------------------------------
# 2. Delete Authz Extensions
# ------------------------------------------------------------------------------
echo "==> [2/4] Deleting Authz Extensions..."
gcloud service-extensions authz-extensions delete "$MA_EXT_NAME" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || true

# ------------------------------------------------------------------------------
# 3. Delete Model Armor Templates
# ------------------------------------------------------------------------------
echo "==> [3/4] Deleting Model Armor Templates..."
gcloud config set api_endpoint_overrides/modelarmor "https://modelarmor.${REGION}.rep.googleapis.com/" --quiet

gcloud beta model-armor templates delete "$REQ_TEMPLATE_ID" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || true

gcloud beta model-armor templates delete "$RESP_TEMPLATE_ID" \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --quiet 2>/dev/null || true

# ------------------------------------------------------------------------------
# 4. Delete Cloud DLP Templates
# ------------------------------------------------------------------------------
echo "==> [4/4] Deleting Cloud DLP Templates..."
TOKEN=$(gcloud auth application-default print-access-token 2>/dev/null || gcloud auth print-access-token)
DLP_BASE="https://dlp.googleapis.com/v2/projects/${PROJECT_ID}/locations/${REGION}"

curl -s -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "${DLP_BASE}/inspectTemplates/${INSPECT_TEMPLATE_ID}" > /dev/null 2>&1 || true

curl -s -X DELETE \
  -H "Authorization: Bearer $TOKEN" \
  -H "x-goog-user-project: ${PROJECT_ID}" \
  "${DLP_BASE}/deidentifyTemplates/${DEIDENTIFY_TEMPLATE_ID}" > /dev/null 2>&1 || true

echo "   ✅ Cleanup complete."
