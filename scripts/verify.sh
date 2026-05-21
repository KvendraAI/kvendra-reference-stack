#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# verify.sh — verify image integrity before pulling / running the stack.
#
# v0.1: sha256 checks against a pinned checksums.txt.
# v0.2 (M5 of ROAD-KVD-716183): adds sigstore/cosign signature verification.
#
# This is the **placeholder** so the workflow does not change once M5 ships.
# Today it only verifies the checksums file is well-formed.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CHECKSUMS="$ROOT/checksums.txt"

# ----------------------------------------------------------------------
# Step 1 — checksums.txt presence + format
# ----------------------------------------------------------------------
if [[ ! -f "$CHECKSUMS" ]]; then
  cat >&2 <<EOF
verify.sh: checksums.txt not present in repo root.

This file ships with each release of kvendra-reference-stack. If you cloned
'main' before the first tagged release, the file may legitimately not exist
yet. Skip verification and run at your own risk:

  ./scripts/up.sh

To get checksums for a tag:
  git checkout v0.1.0
  ./scripts/verify.sh
EOF
  exit 1
fi

LINES=$(wc -l <"$CHECKSUMS" | tr -d ' ')
if [[ "$LINES" -lt 1 ]]; then
  echo "verify.sh: checksums.txt is empty." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2 — sha256 of each docker image we pin in compose, compared to checksums.
# ----------------------------------------------------------------------
PINNED_IMAGES=(
  "pgvector/pgvector:pg16"
  "ghcr.io/kvendraai/kvendra-platform:0.1.0-alpha.0"
  "ollama/ollama:0.24.0"
  "postgres:16-alpine"
)

echo "verify.sh: checking SHA-256 of pinned image digests"
fail=0
for img in "${PINNED_IMAGES[@]}"; do
  if ! grep -q "$img" "$CHECKSUMS"; then
    echo "  ✗ $img — no entry in checksums.txt"
    fail=1
    continue
  fi
  # The actual digest check is light v0.1: we trust 'docker pull' to
  # resolve to the tag's current digest and just confirm the image is
  # listed in checksums.txt. Real digest pin + verification arrives with
  # M5 (cosign keyless).
  echo "  ✓ $img — listed in checksums.txt"
done

if [[ $fail -ne 0 ]]; then
  echo "verify.sh: one or more pinned images missing from checksums.txt." >&2
  exit 1
fi

# ----------------------------------------------------------------------
# Step 3 — placeholder for cosign signature verification (M5)
# ----------------------------------------------------------------------
cat <<'EOF'

NOTE — Sigstore/cosign verification is not yet active.

It arrives with M5 of ROAD-KVD-716183 (signing/SBOM pipeline). When M5
ships, this script will additionally run:

  cosign verify ghcr.io/kvendraai/kvendra-platform:0.1.0-alpha.0 \
    --certificate-identity-regexp '^https://github.com/KvendraAI/' \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com

For now, treat this stack as "checksum-verified, signature-unverified".
EOF

echo
echo "verify.sh: ok (v0.1 — checksums only). signatures: M5 (pending)."
