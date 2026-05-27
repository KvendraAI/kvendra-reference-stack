#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# smoke-cloud.sh — quick smoke test for cloud-mode embeddings.
#
# Reads EMBEDDINGS_API_KEY (+ BASE_URL + MODEL) from .env, posts a single
# embedding request to api.kvendra.cloud, and verifies the response shape.
#
# Exit codes:
#   0  OK — embedding returned with the expected 1024-dim vector.
#   1  unexpected curl / network failure.
#   2  HTTP non-2xx or malformed response.
#   3  API key is still the placeholder — user hasn't signed up yet.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [[ ! -f .env ]]; then
  echo "no .env found. run ./scripts/up.sh first (it copies .env.example)."
  exit 1
fi

# Load .env to read EMBEDDINGS_* vars.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

KEY="${EMBEDDINGS_API_KEY:-}"
URL="${EMBEDDINGS_BASE_URL:-https://api.kvendra.cloud/v1}"
MODEL="${EMBEDDINGS_MODEL:-kvendra-embedding-v1}"

if [[ -z "$KEY" || "$KEY" == "REPLACE_WITH_YOUR_KVENDRA_KEY" ]]; then
  echo "EMBEDDINGS_API_KEY is empty or still the placeholder."
  echo "Sign up at https://kvendra.cloud (free tier) and paste the key into .env."
  exit 3
fi

echo "POST ${URL}/embeddings  (model=${MODEL})"
RESPONSE="$(curl -fsS -X POST "${URL}/embeddings" \
  -H "Authorization: Bearer ${KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"model\":\"${MODEL}\",\"input\":\"kvendra smoke test\"}" \
  || true)"

if [[ -z "$RESPONSE" ]]; then
  echo "no response (network error or HTTP non-2xx)."
  exit 2
fi

DIM="$(printf '%s' "$RESPONSE" | python3 -c '
import json, sys
try:
    payload = json.load(sys.stdin)
    vec = payload["data"][0]["embedding"]
    print(len(vec))
except Exception as exc:
    print("parse_error:%s" % exc)
')"

if [[ "$DIM" == "1024" ]]; then
  echo "OK — embedding returned, dim=${DIM}."
  exit 0
fi

echo "unexpected response shape (dim=${DIM}). raw response:"
printf '%s\n' "$RESPONSE"
exit 2
