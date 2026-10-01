#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# smoke.sh — provider-agnostic end-to-end smoke test for a running stack.
#
# Creates a throw-away entity through the platform MCP endpoint (which
# embeds it with whatever EMBEDDINGS_* provider the stack is configured
# with), runs a semantic entity_search for it, and archives it afterwards.
# Works the same with local Ollama, your own OpenAI-compatible provider or
# the mock provider (the latter only proves the plumbing, not semantics).
#
# Requirements: the stack is up (./scripts/up.sh), curl and python3 on the
# host. Compatible with the stock macOS bash 3.2.
#
# Exit codes:
#   0  OK — entity created and found by semantic search.
#   1  stack not reachable / auth token not available.
#   2  entity_create failed (typically the embeddings provider is
#      unreachable or returns a non-1024-dim vector).
#   3  entity_search failed or did not return the created entity.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
fi

PORT="${PLATFORM_HOST_PORT:-7777}"
BASE="http://localhost:${PORT}"

if ! curl -fsS -o /dev/null "${BASE}/healthz"; then
  echo "platform not reachable at ${BASE}/healthz — run ./scripts/up.sh first."
  exit 1
fi

TOKEN="$(docker compose exec -T kvendra-platform cat /data/auth.token 2>/dev/null || true)"
TOKEN="$(printf '%s' "$TOKEN" | tr -d '\r\n')"
if [[ -z "$TOKEN" ]]; then
  echo "could not read the auth token (docker compose exec kvendra-platform cat /data/auth.token)."
  exit 1
fi

PROVIDER="$(docker compose exec -T kvendra-platform printenv EMBEDDINGS_PROVIDER 2>/dev/null || true)"
PROVIDER="$(printf '%s' "${PROVIDER:-${EMBEDDINGS_PROVIDER:-unknown}}" | tr -d '\r\n')"
MODEL="$(docker compose exec -T kvendra-platform printenv EMBEDDINGS_MODEL 2>/dev/null || true)"
MODEL="$(printf '%s' "${MODEL:-${EMBEDDINGS_MODEL:-}}" | tr -d '\r\n')"
echo "embeddings provider: ${PROVIDER}${MODEL:+ (model=${MODEL})}"
if [[ "$PROVIDER" == "mock" ]]; then
  echo "warning: mock provider — this only checks the plumbing, not semantic quality."
fi

# mcp_call TOOL ARGS_JSON — POST a JSON-RPC tools/call to /mcp and print the
# raw response. The bearer token goes through a curl config on stdin so it
# never shows up in the process list.
mcp_call() {
  local tool="$1" args="$2"
  printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" | curl -sS -K - \
    -X POST "${BASE}/mcp" \
    -H "Content-Type: application/json" \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"${tool}\",\"arguments\":${args}}}"
}

# tool_result — read a JSON-RPC response on stdin and print the tool's JSON
# payload, or "ERROR <detail>" if the call failed.
tool_result() {
  python3 -c '
import json, sys
try:
    resp = json.load(sys.stdin)
except Exception as exc:
    print("ERROR unparseable response: %s" % exc); sys.exit(0)
if "error" in resp:
    print("ERROR %s" % json.dumps(resp["error"])); sys.exit(0)
res = resp.get("result") or {}
text = (res.get("content") or [{}])[0].get("text", "")
if res.get("isError"):
    print("ERROR %s" % text); sys.exit(0)
print(text)
'
}

NONCE="$(date +%s)-$$"
TITLE="kvendra reference stack smoke test ${NONCE}"

echo "entity_create: \"${TITLE}\""
CREATE="$(mcp_call entity_create "{\"entity_type\":\"DOC\",\"project_id\":\"SMOKE\",\"title\":\"${TITLE}\",\"content\":\"\",\"tags\":[\"smoke-test\"]}" | tool_result)"
case "$CREATE" in
  ERROR*)
    echo "entity_create failed: ${CREATE#ERROR }"
    echo "check the embeddings provider: docker compose logs kvendra-platform"
    exit 2
    ;;
esac
ENTITY_ID="$(printf '%s' "$CREATE" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("entity_id",""))')"
if [[ -z "$ENTITY_ID" ]]; then
  echo "entity_create returned no entity_id: ${CREATE}"
  exit 2
fi
echo "  created ${ENTITY_ID}"

cleanup() {
  mcp_call entity_archive "{\"entity_id\":\"${ENTITY_ID}\",\"archive_reason\":\"smoke test cleanup\"}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "entity_search: semantic query for the created entity"
SEARCH="$(mcp_call entity_search "{\"query\":\"${TITLE}\",\"project_id\":\"SMOKE\",\"limit\":20}" | tool_result)"
case "$SEARCH" in
  ERROR*)
    echo "entity_search failed: ${SEARCH#ERROR }"
    exit 3
    ;;
esac
SCORE="$(printf '%s' "$SEARCH" | ENTITY_ID="$ENTITY_ID" python3 -c '
import json, os, sys
hits = json.load(sys.stdin).get("results", [])
for h in hits:
    if h.get("entity_id") == os.environ["ENTITY_ID"]:
        print("%.3f" % h.get("score", 0)); break
')"
if [[ -z "$SCORE" ]]; then
  echo "entity_search did not return ${ENTITY_ID}. raw response:"
  printf '%s\n' "$SEARCH"
  exit 3
fi

echo "OK — ${ENTITY_ID} found by semantic search (score=${SCORE}). archiving it."
exit 0
