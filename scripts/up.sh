#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# up.sh — bring the stack up, wait for healthchecks, preload Ollama models.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ----------------------------------------------------------------------
# 1. Ensure .env exists. Copy from .env.example on first run.
# ----------------------------------------------------------------------
if [[ ! -f .env ]]; then
  echo "no .env found — copying .env.example to .env"
  cp .env.example .env
  echo "edit .env if you want a non-default tier (see docs/tier-a-b-c.md)."
fi

# Load .env so we can read OLLAMA_MODELS_PRELOAD below.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ----------------------------------------------------------------------
# 2. docker compose up -d (4 services).
# ----------------------------------------------------------------------
echo "starting stack (db + platform + ollama + backup)..."
docker compose up -d

# ----------------------------------------------------------------------
# 3. Wait for the platform healthz to be green (max 120s).
# ----------------------------------------------------------------------
echo -n "waiting for kvendra-platform healthz "
for i in $(seq 1 24); do
  if curl -fsS -o /dev/null "http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz"; then
    echo " ok"
    break
  fi
  echo -n "."
  sleep 5
  if [[ $i -eq 24 ]]; then
    echo
    echo "platform did not become healthy within 120s. check logs:"
    echo "  docker compose logs kvendra-platform"
    exit 1
  fi
done

# ----------------------------------------------------------------------
# 4. Preload Ollama models (if requested).
# ----------------------------------------------------------------------
MODELS="${OLLAMA_MODELS_PRELOAD:-}"
if [[ -n "$MODELS" ]]; then
  echo "preloading Ollama models: $MODELS"
  IFS=',' read -r -a model_list <<<"$MODELS"
  for m in "${model_list[@]}"; do
    m_trimmed="${m## }"
    m_trimmed="${m_trimmed%% }"
    if [[ -z "$m_trimmed" ]]; then continue; fi
    echo "  pulling $m_trimmed"
    docker compose exec -T kvendra-ollama ollama pull "$m_trimmed" \
      || echo "  warning: pull failed for $m_trimmed (continuing)"
  done
fi

# ----------------------------------------------------------------------
# 5. Print bootstrap token + next steps.
# ----------------------------------------------------------------------
echo
echo "==============================================="
echo "stack ready."
echo
TOKEN_PATH="$ROOT/data/auth.token"
if [[ -f "$TOKEN_PATH" ]]; then
  echo "auth token (bearer for MCP):"
  cat "$TOKEN_PATH"
  echo
else
  echo "auth token not yet generated."
  echo "wait a few seconds and re-check:  cat $TOKEN_PATH"
fi
echo
echo "endpoints:"
echo "  platform healthz:   http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz"
echo "  platform MCP:       http://localhost:${PLATFORM_HOST_PORT:-7777}/mcp"
echo "  ollama API:         http://localhost:${OLLAMA_HOST_PORT:-11434}/api/version"
echo
echo "next: configure your CLI / orchestrator on the host. see README.md."
