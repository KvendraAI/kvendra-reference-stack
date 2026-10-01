# Kvendra Reference Stack

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

**Docker compose for the full Kvendra self-hosted OSS stack** —
Postgres + pgvector, kvendra-platform (KB engine, AGPL-3.0), a backup
sidecar, and Ollama (embeddings server, MIT; started by default). The CLI
runs on your host. Orchestration is handled by **Claude Code** (or any
MCP-native IDE) — see PAT-KVD-4AF89B for the rationale.

This repo is **M4 of `ROAD-KVD-716183`** (Self-Hosted Community) — the
last implementation milestone before signing (M5) and the public
`/install` page update (M6).

## Two paths

| Path | Audience | Time | Trust model |
|---|---|---|---|
| **A — docker compose preconfigured** | Developers who want a stack up in 5 minutes | ~5 min | Trust Kvendra signing (M5 once shipped) + image digest |
| **B — build-from-source** | Banks, regulated teams, security audits | ~30 min | Trust nobody — compile every component from public source |

Both paths produce a functionally equivalent stack.

## Quick start (Path A)

```bash
git clone https://github.com/KvendraAI/kvendra-reference-stack
cd kvendra-reference-stack
cp .env.example .env
# Default: embeddings by a local Ollama container (mxbai-embed-large).
# No account or API key needed. See docs/modes.md for alternatives.
./scripts/up.sh
./scripts/smoke.sh   # optional: create + semantic search end to end
```

`up.sh` starts the stack, waits for healthchecks and pulls the
embeddings model on first run (≈700 MB download).

Then register the platform as an MCP server in **Claude Code** on your host:

```bash
# 1. Read the bootstrap auth token:
TOKEN="$(cat ./data/auth.token)"

# 2. Add the platform as a Claude Code MCP server:
claude mcp add kvendra-platform http://localhost:7777/mcp \
  -H "Authorization: Bearer $TOKEN"

# 3. Restart Claude Code so the new MCP server is picked up.
```

Any other MCP-native IDE (Cursor, Windsurf, etc.) can consume the same
`http://localhost:7777/mcp` endpoint with the same bearer header.

**Alternative: your own embeddings provider** — point the
`EMBEDDINGS_*` vars in `.env` at any OpenAI-compatible endpoint serving a
natively 1024-dim model (e.g. vLLM/TEI with `mxbai-embed-large` or
`bge-large-en-v1.5`, Mistral `mistral-embed`) and start with
`./scripts/up.sh --no-ollama`. Switching provider means re-embedding
your existing entities. See `docs/modes.md`.

## Build-from-source (Path B)

```bash
./scripts/build-from-source.sh
```

This clones `kvendra-platform` from `github.com/KvendraAI/kvendra-platform`,
builds the docker image locally (multi-stage Dockerfile), and overrides
the `image:` field in `docker-compose.yml` to use your local build instead
of the upstream `kvendra/kvendra-platform` image. No image is pulled
from a registry.

For Ollama and Postgres, the upstream images are pulled by default (they
are themselves open-source). To run **everything** from source, see
`docs/troubleshooting.md` § "Fully from-source build".

## Verification (placeholder until M5)

```bash
./scripts/verify.sh
```

Today, `verify.sh` checks SHA-256 of the pinned image digests against
`./checksums.txt`. **Sigstore/cosign signature verification arrives with
M5** of `ROAD-KVD-716183` (signing pipeline). The placeholder is in
place so the workflow does not change once M5 ships.

## What's NOT in the stack

By design (see `ROAD-KVD-716183` principle 4 and `PAT-KVD-819856` L3):

- **`kvendra-cli`** — lives on your host. The CLI is a zero-knowledge
  vault; putting it in a container with a master password in an env
  var would defeat its threat model. Install separately:
  `cargo install kvendra` (or download a signed binary from
  `github.com/KvendraAI/kvendra-cli/releases`).
- **The orchestrator** — Claude Code (or any other MCP-native IDE) runs
  on your host and connects to the platform via the MCP endpoint at
  `localhost:7777/mcp`. See PAT-KVD-4AF89B for why orchestration is a
  host-side concern rather than a container.
- **Helm chart** — that's a separate track (`kvendra-helm`), aimed at
  k8s production rather than developer self-hosting.

## Hardware requirements

For the **full local stack** (Tier B — both LLM and embeddings on Ollama):

| Resource | Minimum | Recommended |
|---|---|---|
| RAM | 16 GB | 32 GB |
| Disk | 20 GB free | 50 GB free |
| GPU | None (CPU works for embeddings) | 8 GB VRAM for LLM inference |

For **embeddings only** (the default: Ollama serves `mxbai-embed-large`,
the LLM is whatever your orchestrator uses): 8 GB RAM is enough. With
your own embeddings provider (`--no-ollama`), 4 GB RAM is enough.

**Caveat from the M2 spike**: an Apple Silicon laptop without a
discrete GPU can run **`mxbai-embed-large` (embeddings)** comfortably,
but a **Llama 3.1 8B (LLM)** inference will be slow (~1–2 tok/s on
CPU). End-to-end empirical validation with both running on an 8 GB
laptop is still **pending**; we'll publish the report in
[`reports/`](./reports/) once it's done on adequate hardware.

## Operating modes

See [`docs/modes.md`](./docs/modes.md) for the full env-var gradient and
the trade-offs between the Ollama default, your own provider, and mock.

## Troubleshooting

See [`docs/troubleshooting.md`](./docs/troubleshooting.md).

Common starting points:

- **"Cannot connect to Docker daemon"** → `colima start` (macOS) or
  `systemctl start docker` (Linux).
- **Ollama doesn't pull models** → bandwidth / disk. Run
  `docker compose logs kvendra-ollama` and check free space.
- **Healthcheck stuck** → first start can take ~60s while pgvector
  initialises. Wait, then `docker compose ps`.

## Contributing

Issues and PRs welcome. Scope is narrow: this repo packages other
people's work. Substantive changes go to the upstream repos.

- Stack composition / scripts → here.
- KB engine behavior → `kvendra-platform`.
- Skills content → `KvendraAI/kvendra-skills` (Apache-2.0).

## License

MIT — see [`LICENSE`](./LICENSE). The components packaged retain their
own licenses (AGPL-3.0 for `kvendra-platform`, Apache-2.0 for skills,
MIT for Ollama, PostgreSQL License for Postgres). The MIT applies only
to this orchestration layer (the `compose`, scripts, and docs).

---

- Project: [kvendra.com](https://kvendra.com)
- Org: [github.com/KvendraAI](https://github.com/KvendraAI)
- Tracked in: `ROAD-KVD-716183` M4
