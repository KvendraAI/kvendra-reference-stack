<!-- SPDX-License-Identifier: MIT -->

# Troubleshooting

Common issues with the Kvendra Reference Stack and how to resolve them.

---

## "Cannot connect to Docker daemon"

The Docker daemon is not running.

- **macOS**: install Colima or Docker Desktop, then `colima start` or
  open Docker Desktop.
- **Linux**: `sudo systemctl start docker` (and `enable` if you want it
  persistent across reboots).
- **Windows**: install Docker Desktop with the WSL 2 backend.

---

## `./scripts/up.sh` hangs at "waiting for kvendra-platform healthz"

First boot can take **60–90 seconds** while pgvector initialises and the
platform runs migrations. Wait. If it times out at 120s, check:

```bash
docker compose logs kvendra-platform
docker compose logs kvendra-db
```

Common causes:

- Port conflict on host (`7777` already in use). Set
  `PLATFORM_HOST_PORT=8888` in `.env` and re-run `up.sh`.
- Postgres credentials mismatch between platform and db. Make sure you
  haven't edited only one of `POSTGRES_USER` / `POSTGRES_PASSWORD` in
  `.env` without `docker compose down -v` (volumes hold the old creds).
- Out of memory. The platform image needs ≈300 MB. Postgres ≈500 MB.
  Ollama loads models lazily, but if a model is already loaded it can
  pin 5–10 GB. Use `docker stats` to see.

---

## Ollama pull fails / model never downloads

```bash
docker compose logs kvendra-ollama
```

If you see `pull model manifest: file does not exist`, the model name
is wrong (Ollama is case-sensitive on tags; `llama3.1:8b` not
`Llama3.1:8B`). Fix `OLLAMA_MODELS_PRELOAD` in `.env`.

If you see `not enough free disk space`, you need ≥10 GB free. Default
volume `kvendra_ref_ollama_models` lives in your Docker root (usually
`/var/lib/docker/volumes/`). To inspect:

```bash
docker volume inspect kvendra_ref_ollama_models
```

---

## "out of memory" / OOMKilled

Llama 3.1 8B needs ≈5 GB RAM (Q4) up to ≈10 GB (Q8). On a 8 GB machine
with the rest of the stack running, you'll thrash. Options:

1. **Smaller model**: try `llama3.2:3b` or `phi3.5:3.8b`.
2. **Hybrid L1** (Tier A): skip local Ollama entirely if you only need
   embeddings from the cloud. `docker compose up -d kvendra-db
   kvendra-platform kvendra-backup` (omit ollama).
3. **Bigger machine**: 16 GB RAM minimum for the full local stack.

---

## "Embeddings provider error" in platform logs

The platform tried to call the embeddings endpoint and got an error.

```bash
docker compose logs kvendra-platform | grep openai-compatible
```

- `Embeddings provider unreachable at http://kvendra-ollama:11434/v1/embeddings`
  → Ollama isn't healthy yet. `docker compose ps kvendra-ollama` should
  show `healthy`. If not, see "Ollama pull fails" above.
- `Expected dim 1024, got 768 from model nomic-embed-text`
  → You used the wrong embedding model. The stack pins 1024-dim. Use
  `mxbai-embed-large` (or any other 1024-dim model). See
  `kvendra-platform/docs/embeddings.md` for the dim contract.
- `Embeddings provider timeout after 30000ms`
  → Cold model load on a slow machine. Raise the timeout in `.env`:
  `EMBEDDINGS_TIMEOUT_MS=120000`.

---

## "auth.token not yet generated"

The platform writes a bootstrap token to `/data/auth.token` (mode 0600)
on first boot. If it's not there:

```bash
docker compose exec kvendra-platform ls -la /data/
docker compose logs kvendra-platform | grep -i token
```

The most common cause is the platform crashed before bootstrap. Read
the logs from the top.

---

## Stack runs but my CLI on the host can't reach it

The platform listens on `localhost:7777` (or whatever you set
`PLATFORM_HOST_PORT` to). From the host:

```bash
curl http://localhost:7777/healthz
```

If this works but your CLI doesn't, check the CLI config — it might be
pointing at `127.0.0.1:7777` (works) vs `http://localhost:7777/mcp` (the
MCP endpoint, the `/mcp` suffix matters).

For cline:
```json
// ~/.cline/data/settings/cline_mcp_settings.json
{
  "mcpServers": {
    "kvendra-platform": {
      "url": "http://localhost:7777/mcp",
      "headers": {
        "Authorization": "Bearer <token from data/auth.token>"
      }
    }
  }
}
```

---

## How do I clean everything up?

```bash
docker compose down -v       # stops containers, removes volumes (data lost)
rm -rf data backups sources  # local state
```

To stop without losing data:

```bash
docker compose down          # stops containers, KEEPS volumes
```

---

## Fully from-source build (no upstream images at all)

The default `build-from-source.sh` only rebuilds `kvendra-platform`. To
also build Ollama, Postgres, and the backup sidecar from source:

1. Clone the upstream repos (`pgvector/pgvector`, `ollama/ollama`,
   `postgres/postgres`).
2. Build each (`docker build .` in their respective trees).
3. Add their local tags to `docker-compose.override.yml`:

   ```yaml
   services:
     kvendra-db:
       image: pgvector-local:pg16
     kvendra-ollama:
       image: ollama-local:0.24.0
     kvendra-backup:
       image: postgres-local:16-alpine
   ```

This is rarely needed unless you have an extremely strict supply-chain
policy. The default approach (pull official images for Postgres / Ollama,
build only the Kvendra-controlled component) is what most banks accept
after reviewing the upstream repos' security posture.

---

## Where do I report issues?

GitHub Issues on
[`KvendraAI/kvendra-reference-stack`](https://github.com/KvendraAI/kvendra-reference-stack/issues).

Bugs in **kvendra-platform** itself go to
[`KvendraAI/kvendra-platform`](https://github.com/KvendraAI/kvendra-platform/issues).

Bugs in the **community skills** go to
[`KvendraAI/skills`](https://github.com/KvendraAI/skills/issues).
