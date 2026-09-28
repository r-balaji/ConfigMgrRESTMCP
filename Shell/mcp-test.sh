#!/usr/bin/env bash
# Quick curl harness for the Salesforce-hosted MCP endpoint.
#
# Usage:
#   export SF_MCP_ACCESS_TOKEN='<short-lived access token>'
#   export SF_MCP_URL='https://api.salesforce.com/platform/mcp/v1/sandbox/custom/ConfigMCP'
#   export SF_MCP_PRODUCT_ID='<optional Loan Product Id>'
#   ./Shell/mcp-test.sh
#
# Never place Salesforce access or refresh tokens in this file. Keep tokens in
# the environment and revoke them after testing.

set -u

# ── Configuration ───────────────────────────────────────────────────────────
ACCESS_TOKEN="${SF_MCP_ACCESS_TOKEN:-}"
MCP_URL="${SF_MCP_URL:-https://api.salesforce.com/platform/mcp/v1/sandbox/custom/ConfigMCP}"
PRODUCT_ID="${SF_MCP_PRODUCT_ID:-}"

# ── Sanity checks ───────────────────────────────────────────────────────────
if [[ -z "$ACCESS_TOKEN" ]]; then
  echo "Set SF_MCP_ACCESS_TOKEN to a short-lived Salesforce access token before running." >&2
  exit 1
fi

MCP_SESSION_ID=""

# ── Helper: send a JSON-RPC body to the MCP endpoint and print the response.
#    After `initialize` succeeds, we capture the `Mcp-Session-Id` response
#    header and send it back on every subsequent call. Without that, the
#    gateway 400s with "Session Key missing, but it's not an initialize request".
call() {
  local desc="$1"
  local body="$2"
  echo
  echo "═══════════════════════════════════════════════════════════════════"
  echo "▸ $desc"
  echo "  Body: $body"
  echo "═══════════════════════════════════════════════════════════════════"

  local hdr_arg=()
  if [[ -n "$MCP_SESSION_ID" ]]; then
    hdr_arg+=(-H "Mcp-Session-Id: $MCP_SESSION_ID")
  fi

  # Salesforce streams responses as SSE. Capture body + headers separately.
  # --max-time gives the stream up to 120s to close; --no-buffer makes curl
  # write each chunk as it arrives rather than waiting for the full body.
  local hdr_file body_file
  hdr_file=$(mktemp)
  body_file=$(mktemp)
  curl -sS --no-buffer --max-time 120 -X POST "$MCP_URL" \
    -D "$hdr_file" \
    -o "$body_file" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json, text/event-stream" \
    -H "MCP-Protocol-Version: 2024-11-05" \
    ${hdr_arg[@]+"${hdr_arg[@]}"} \
    -d "$body" || echo "(curl exited non-zero — possibly timed out streaming)"
  echo "--- response body ($(wc -c < "$body_file") bytes) ---"
  cat "$body_file"
  echo
  echo "--- response headers ---"
  cat "$hdr_file"

  # First call (initialize) returns mcp-session-id; stash it for the rest.
  if [[ -z "$MCP_SESSION_ID" ]]; then
    MCP_SESSION_ID=$(grep -i '^mcp-session-id:' "$hdr_file" | awk -F': ' '{print $2}' | tr -d '\r\n')
    if [[ -n "$MCP_SESSION_ID" ]]; then
      echo "▸ Captured MCP session id: $MCP_SESSION_ID"
    fi
  fi
  rm -f "$hdr_file" "$body_file"
}

# ── Sequence of calls ───────────────────────────────────────────────────────

# 0. Sanity check: hit the identity / userinfo endpoint to see which scopes
#    Salesforce actually granted to this token. If `mcp_api` is missing here,
#    the MCP gateway will 401 every call.
echo
echo "═══════════════════════════════════════════════════════════════════"
echo "▸ Token introspection (scopes granted to this token)"
echo "═══════════════════════════════════════════════════════════════════"
curl -sS -i "https://login.salesforce.com/services/oauth2/userinfo" \
  -H "Authorization: Bearer $ACCESS_TOKEN"
echo

# 1. Handshake — what does the server say about itself?
call "initialize" '{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2024-11-05",
    "capabilities": {},
    "clientInfo": { "name": "configmanager-curl", "version": "0.1" }
  }
}'

# 1b. Per MCP spec, the client MUST send `notifications/initialized` after the
#     initialize response before issuing further requests. Salesforce's gateway
#     appears to gate `tools/list` on this — without it, tools/list returns
#     HTTP 200 with empty body. (No `id` field — this is a notification, not a
#     request — server replies with 202 Accepted and no body.)
call "notifications/initialized" '{
  "jsonrpc": "2.0",
  "method": "notifications/initialized"
}'

# 2. Discover what tools are registered.
call "tools/list" '{
  "jsonrpc": "2.0",
  "id": 2,
  "method": "tools/list"
}'

# 3. Invoke list_products. The Setup UI shows two strings per tool:
#    - bold "w22loan__ListProductsAction" (display label)
#    - parenthesized "w22loan_ListProductsActionapex_w22loan_ListProductsAction"
#      (canonical tool identifier — what the gateway actually dispatches on)
call "tools/call list_products" '{
  "jsonrpc": "2.0",
  "id": 3,
  "method": "tools/call",
  "params": {
    "name": "w22loan_ListProductsActionapex_w22loan_ListProductsAction",
    "arguments": { "inputs": [ { "statusFilter": "" } ] }
  }
}'

if [[ -n "$PRODUCT_ID" ]]; then
  call "tools/call get_product" "{
    \"jsonrpc\": \"2.0\",
    \"id\": 4,
    \"method\": \"tools/call\",
    \"params\": {
      \"name\": \"w22loan_GetProductActionapex_w22loan_GetProductAction\",
      \"arguments\": { \"inputs\": [ { \"productId\": \"$PRODUCT_ID\" } ] }
    }
  }"
else
  echo "Skipping get_product; set SF_MCP_PRODUCT_ID to exercise that tool."
fi
