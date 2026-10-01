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

# ----------------------------------------------------------------------
# 1b. Parse flags BEFORE sourcing .env, so the legacy-.env migration below
#     can rewrite the embeddings vars before we load them.
# ----------------------------------------------------------------------
NO_OLLAMA=0
for arg in "$@"; do
  case "$arg" in
    --with-ollama)
      # Kept as a no-op alias: Ollama is the default now. Accepting the flag
      # keeps previously published commands (README, llms.txt) working.
      ;;
    --no-ollama)
      NO_OLLAMA=1
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./scripts/up.sh [--no-ollama]

Brings up the Kvendra reference stack. By default it starts the local
kvendra-ollama container and pulls the embeddings model (mxbai-embed-large,
1024-dim) — no account or API key needed.

Options:
  --no-ollama     Do not start kvendra-ollama and skip the model preload.
                  Use this when EMBEDDINGS_* in .env point at your own
                  OpenAI-compatible provider (natively 1024-dim model).
  --with-ollama   Accepted for backwards compatibility; no effect (Ollama
                  is the default).
  -h, --help      Show this help.

See docs/modes.md for the available modes.
USAGE
      exit 0
      ;;
    *)
      echo "warning: ignoring unknown option: $arg (see ./scripts/up.sh --help)" >&2
      ;;
  esac
done

# ----------------------------------------------------------------------
# 1c. Migrate legacy .env files that still point at the retired Kvendra
#     Cloud embeddings endpoint (the old hosted base URL / model alias).
#     That service no longer exists, so such a stack cannot embed anything.
#     We rewrite the EMBEDDINGS_* lines in place to the local Ollama
#     defaults — idempotent (a migrated .env no longer matches) and marked
#     with a comment so it's clear they were set by this script.
# ----------------------------------------------------------------------

MIGRATION_MARKER="# set by up.sh (kvendra cloud embeddings retired)"

# set_env_var KEY VALUE [MARKER] — set KEY=VALUE in .env, replacing an
# existing (commented or uncommented) definition of KEY in place, or
# appending if absent. If MARKER is non-empty, the marker comment line is
# emitted immediately before KEY (added if missing, not duplicated).
# Idempotent: running it again with the same VALUE leaves .env unchanged.
# Uses awk + temp file for portability (BSD/macOS sed has no portable -i).
set_env_var() {
  local key="$1" value="$2" marker="${3:-}"
  awk -v key="$key" -v val="$value" -v marker="$marker" '
    # Drop any pre-existing standalone marker line; we re-emit it (once)
    # right before the key, so repeated runs do not pile up markers.
    marker != "" && $0 == marker { next }
    !replaced && $0 ~ "^[[:space:]]*#?[[:space:]]*" key "=" {
      if (marker != "") print marker
      print key "=" val
      replaced = 1
      next
    }
    { print }
    END {
      if (!replaced) {
        if (marker != "") print marker
        print key "=" val
      }
    }
  ' .env > .env.tmp && mv .env.tmp .env
}

if grep -qE '^[[:space:]]*EMBEDDINGS_(BASE_URL|MODEL)=.*(api\.kvendra\.cloud|kvendra-embedding-v1)' .env; then
  echo
  echo "==============================================="
  echo "NOTE: your .env points at the Kvendra Cloud embeddings endpoint,"
  echo "which has been retired. Rewriting EMBEDDINGS_* to the local Ollama"
  echo "defaults (mxbai-embed-large, 1024-dim)."
  echo
  echo "If your knowledge base already holds entities embedded with the old"
  echo "provider, re-embed them: vectors from different providers/models are"
  echo "not comparable, even at the same dimension. See docs/modes.md."
  echo "==============================================="
  echo
  set_env_var EMBEDDINGS_PROVIDER openai-compatible "$MIGRATION_MARKER"
  set_env_var EMBEDDINGS_BASE_URL http://kvendra-ollama:11434/v1
  set_env_var EMBEDDINGS_MODEL mxbai-embed-large
  set_env_var EMBEDDINGS_API_KEY ""
fi

# ----------------------------------------------------------------------
# 1d. Load .env (now possibly rewired) into the environment so compose
#     interpolates the right EMBEDDINGS_* values, and so we can read
#     OLLAMA_MODELS_PRELOAD / PLATFORM_HOST_PORT below.
# ----------------------------------------------------------------------
set -a
# shellcheck disable=SC1091
. ./.env
set +a

# ----------------------------------------------------------------------
# 2. docker compose up.
# ----------------------------------------------------------------------
if [[ $NO_OLLAMA -eq 1 ]]; then
  echo "starting stack without Ollama (db + platform + backup)..."
  if grep -qE '^[[:space:]]*EMBEDDINGS_BASE_URL=.*kvendra-ollama' .env; then
    echo "warning: --no-ollama but EMBEDDINGS_BASE_URL in .env still points at"
    echo "         kvendra-ollama. Set your own provider in .env (see docs/modes.md)."
  fi
  docker compose up -d --scale kvendra-ollama=0
else
  echo "starting stack (db + platform + ollama + backup)..."
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
# 4. Preload Ollama models (skipped with --no-ollama).
# ----------------------------------------------------------------------
if [[ $NO_OLLAMA -eq 0 ]]; then
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
# The auth token lives INSIDE the platform container (named volume
# kvendra_ref_platform_data mounted at /data), not on the host. Read it via
# `docker compose exec` on the platform SERVICE name (kvendra-platform), not
# the container_name. It can lag the healthcheck by a second or two, so retry.
TOKEN=""
for attempt in 1 2 3; do
  TOKEN="$(docker compose exec -T kvendra-platform cat /data/auth.token 2>/dev/null || true)"
  TOKEN="${TOKEN//$'\r'/}"
  if [[ -n "$TOKEN" ]]; then
    break
  fi
  sleep 2
done
if [[ -n "$TOKEN" ]]; then
  echo "auth token (bearer for MCP):"
  echo "$TOKEN"
  echo
else
  echo "auth token not yet generated."
  echo "wait a few seconds and re-check:  docker compose exec kvendra-platform cat /data/auth.token"
fi
echo
echo "endpoints:"
echo "  platform healthz:   http://localhost:${PLATFORM_HOST_PORT:-7777}/healthz"
echo "  platform MCP:       http://localhost:${PLATFORM_HOST_PORT:-7777}/mcp"
if [[ $NO_OLLAMA -eq 0 ]]; then
  echo "  ollama API:         http://localhost:${OLLAMA_HOST_PORT:-11434}/api/version"
fi
echo
echo "next: configure your CLI / orchestrator on the host. see README.md."
echo "smoke test (create + semantic search): ./scripts/smoke.sh"
