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
  echo "edit .env if you want a non-default mode (see docs/modes.md)."
fi

# Load .env so we can read OLLAMA_MODELS_PRELOAD below.
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ----------------------------------------------------------------------
# 2. Parse flags and docker compose up.
# ----------------------------------------------------------------------
WITH_OLLAMA=0
for arg in "$@"; do
  case "$arg" in
    --with-ollama)
      WITH_OLLAMA=1
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./scripts/up.sh [--with-ollama]

Brings up the Kvendra reference stack.

Options:
  --with-ollama   Also start the kvendra-ollama service (opt-in profile).
                  Use this if you want everything local instead of using
                  api.kvendra.cloud embeddings.
  -h, --help      Show this help.

Default mode (no flag): cloud embeddings via api.kvendra.cloud. Make sure
EMBEDDINGS_API_KEY in .env is set to your real key (sign up at
https://kvendra.cloud).
USAGE
      exit 0
      ;;
  esac
done

if [[ $WITH_OLLAMA -eq 1 ]]; then
  echo "starting stack with Ollama profile (db + platform + ollama + backup)..."
  COMPOSE_PROFILES=ollama docker compose --profile ollama up -d
else
  echo "starting stack (db + platform + backup)..."
  docker compose up -d
fi

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
# 4. Preload Ollama models (only if --with-ollama was passed).
# ----------------------------------------------------------------------
if [[ $WITH_OLLAMA -eq 1 ]]; then
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
if [[ $WITH_OLLAMA -eq 1 ]]; then
  echo "  ollama API:         http://localhost:${OLLAMA_HOST_PORT:-11434}/api/version"
fi
echo
echo "next: configure your CLI / orchestrator on the host. see README.md."

# ----------------------------------------------------------------------
# 6. Detect placeholder API key and warn the user.
# ----------------------------------------------------------------------
if [[ $WITH_OLLAMA -eq 0 ]] && grep -qE '^EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY' .env; then
  echo
  echo "==============================================="
  echo "⚠️  EMBEDDINGS_API_KEY is still set to the placeholder."
  echo
  echo "The default mode is Kvendra Cloud embeddings (api.kvendra.cloud)."
  echo "Without a real key, entity_create and entity_search will fail."
  echo
  echo "Two options:"
  echo "  1. Sign up at https://kvendra.cloud (free tier, 200k tok/month)"
  echo "     and replace REPLACE_WITH_YOUR_KVENDRA_KEY in .env with your real key."
  echo "  2. Switch to local Ollama: stop the stack, edit .env per the"
  echo "     'Ollama local' block, then re-run:  ./scripts/up.sh --with-ollama"
  echo
  echo "See docs/modes.md for details."
  echo "==============================================="
fi
