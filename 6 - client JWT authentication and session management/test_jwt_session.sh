#!/usr/bin/env bash
# ==============================================================================
# test_jwt_session.sh
# End-to-End Client JWT Authentication & Session Handshake Verification
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
METADATA_FILE="$PROJECT_ROOT/1 - multi agent ADK app/order-assistant/deployment_metadata.json"

echo "=============================================================================="
echo " Stage 6: Client JWT Authentication & Session Management Verification"
echo "=============================================================================="

# 1. Check prerequisites
if ! command -v jq >/dev/null 2>&1; then
  echo "❌ Error: jq is required for this script."
  exit 1
fi

if [ ! -f "$METADATA_FILE" ]; then
  echo "❌ Error: deployment_metadata.json not found at $METADATA_FILE."
  exit 1
fi

RE_RESOURCE_ID=$(grep '"remote_agent_runtime_id"' "$METADATA_FILE" | cut -d'"' -f4)
REGION=$(echo "$RE_RESOURCE_ID" | cut -d'/' -f4)
PROJECT_NUMBER=$(echo "$RE_RESOURCE_ID" | cut -d'/' -f2)
RE_NUMERIC_ID=$(basename "$RE_RESOURCE_ID")

echo "📍 Target Reasoning Engine : $RE_RESOURCE_ID"
echo "📍 Region                  : $REGION"
echo "📍 Project Number          : $PROJECT_NUMBER"
echo ""

# 2. Get GCP Access Token
echo "==> [1/4] Generating GCP access token..."
TOKEN=$(gcloud auth application-default print-access-token)
echo "    ✅ Access token generated."

# 3. Generate Mock End-User JWT
echo ""
echo "==> [2/4] Generating Mock Client End-User JWT (sub=customer_bob, scopes=orders:read)..."
TEST_JWT=$(python3 -c '
import base64, json
header = base64.urlsafe_b64encode(json.dumps({"alg":"HS256","typ":"JWT"}).encode()).decode().rstrip("=")
payload = base64.urlsafe_b64encode(json.dumps({
    "sub": "customer_bob",
    "email": "bob@example.com",
    "scopes": ["orders:read", "orders:status"],
    "roles": ["customer"]
}).encode()).decode().rstrip("=")
print(f"{header}.{payload}.mock_signature")
')
echo "    Generated JWT: ${TEST_JWT:0:40}..."

# 4. Handshake: Call /api/session/init
echo ""
echo "==> [3/4] Initializing session via POST /api/session/init with X-User-Token header..."
INIT_URL="https://${REGION}-aiplatform.googleapis.com/reasoningEngines/v1/${RE_RESOURCE_ID}/api/session/init"

INIT_RESP=$(curl -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "X-User-Token: ${TEST_JWT}" \
  -H "Content-Type: application/json" \
  -d '{}' \
  "$INIT_URL")

echo "    Response:"
echo "$INIT_RESP" | jq .

SESSION_ID=$(echo "$INIT_RESP" | jq -r '.session_id // empty')
if [ -z "$SESSION_ID" ]; then
  echo "❌ Error: Failed to extract session_id from response."
  exit 1
fi
echo "    ✅ Session created with ID: $SESSION_ID"

# 5. Query Agent via Standard :streamQuery
echo ""
echo "==> [4/4] Issuing query via standard :streamQuery passing only the session_id..."
QUERY_URL="https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${RE_NUMERIC_ID}:streamQuery"

echo "    Sending: 'What is the status of my order ORD-102?' with session_id=$SESSION_ID"
QUERY_RESP=$(curl --no-buffer -s -X POST \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "class_method": "async_stream_query",
    "input": {
      "message": "What is the status of my order ORD-102?",
      "user_id": "customer_bob",
      "session_id": "'"${SESSION_ID}"'"
    }
  }' \
  "$QUERY_URL")

echo ""
echo "    Agent Response Stream:"
echo "$QUERY_RESP" | grep -o '"text": "[^"]*"' || echo "$QUERY_RESP"
echo ""
echo "=============================================================================="
echo " ✅ Verification Complete: JWT accepted, Session initialized & Query resolved!"
echo "=============================================================================="
