#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# verify.sh — verify image signatures + SBOM attestations before running the stack.
#
# Uses Sigstore/cosign keyless verification against the GitHub Actions OIDC
# identity that signs the kvendra-platform images during the release pipeline
# (.github/workflows/release.yml in KvendraAI/kvendra-platform).
#
# Requirements: cosign v2+ installed. Install on macOS: `brew install cosign`.
# On Linux: see https://docs.sigstore.dev/system_config/installation.
#
# Refs: ROAD-KVD-716183 M5 (signing/SBOM pipeline).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# ----------------------------------------------------------------------
# Images pinned in docker-compose.yml. Update on each version bump.
# ----------------------------------------------------------------------
KVENDRA_IMAGES=(
  "docker.io/kvendra/kvendra-platform:0.1.0-alpha.0"
)

# These are upstream public-registry images. We do not verify their signatures
# here (signed by their respective projects, not by Kvendra). If your security
# policy requires verifying these too, see docs/signing.md § "verifying upstream".
UPSTREAM_IMAGES=(
  "pgvector/pgvector:pg16"
  "ollama/ollama:0.24.0"
  "postgres:16-alpine"
)

# ----------------------------------------------------------------------
# Pre-flight: cosign installed?
# ----------------------------------------------------------------------
if ! command -v cosign >/dev/null 2>&1; then
  cat >&2 <<EOF
verify.sh: cosign not found in PATH.

Install:
  macOS:   brew install cosign
  Linux:   https://docs.sigstore.dev/system_config/installation

Or skip verification at your own risk:
  SKIP_VERIFY=1 ./scripts/up.sh
EOF
  exit 1
fi

# ----------------------------------------------------------------------
# Step 1 — verify Kvendra-signed images (cosign keyless).
# ----------------------------------------------------------------------
echo "verify.sh: checking Sigstore/cosign signatures on Kvendra images"
fail=0

for img in "${KVENDRA_IMAGES[@]}"; do
  echo "  verifying $img"
  if cosign verify "$img" \
      --certificate-identity-regexp '^https://github\.com/KvendraAI/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      >/dev/null 2>&1; then
    echo "    ✓ signature OK (keyless OIDC, KvendraAI/* identity)"
  else
    echo "    ✗ signature verification FAILED"
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  cat >&2 <<EOF

verify.sh: one or more signature verifications failed.

This may mean:
  1. The image was not signed yet (M5 of ROAD-KVD-716183 has not shipped a
     signed release of this version). Check:
       https://github.com/KvendraAI/kvendra-platform/releases
  2. Network issue reaching Sigstore Rekor / Fulcio.
  3. The image was tampered with (rare but possible — investigate).

Do NOT proceed with up.sh until this is resolved, unless you accept the risk:
  SKIP_VERIFY=1 ./scripts/up.sh
EOF
  exit 1
fi

# ----------------------------------------------------------------------
# Step 2 — verify SBOM attestations.
# ----------------------------------------------------------------------
echo "verify.sh: checking SPDX SBOM attestations on Kvendra images"

for img in "${KVENDRA_IMAGES[@]}"; do
  echo "  verifying SBOM attestation for $img"
  if cosign verify-attestation "$img" \
      --certificate-identity-regexp '^https://github\.com/KvendraAI/' \
      --certificate-oidc-issuer https://token.actions.githubusercontent.com \
      --type spdxjson \
      >/dev/null 2>&1; then
    echo "    ✓ SBOM attestation OK"
  else
    echo "    ⚠ SBOM attestation not found or invalid (skipping — non-fatal)"
  fi
done

# ----------------------------------------------------------------------
# Step 3 — note about upstream images.
# ----------------------------------------------------------------------
echo
echo "verify.sh: upstream images (NOT verified by this script):"
for img in "${UPSTREAM_IMAGES[@]}"; do
  echo "    $img"
done
echo "  These are public-registry images signed (if at all) by their own"
echo "  projects. See docs/signing.md to verify them under stricter policy."

echo
echo "verify.sh: ok. Run ./scripts/up.sh to bring the stack up."
