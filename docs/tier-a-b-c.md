<!-- SPDX-License-Identifier: MIT -->

# Tier A / B / C — env-var gradient

The Kvendra Self-Hosted Community stack is **one set of containers** but
**three possible operating modes**, selected via env vars. The three tiers
trade off privacy vs alignment with the SaaS vs ops simplicity.

## At a glance

| Aspect | Tier B (full local) | Tier A (hybrid L1) | Hybrid L2 | (Tier C, managed SaaS) |
|---|---|---|---|---|
| Embeddings | Local Ollama | kvendra.cloud (free tier) | kvendra.cloud (free tier) | kvendra.cloud (paid Pro) |
| LLM | Local Ollama | Local Ollama | Local Ollama | Claude / kvendra.cloud |
| CLI on host | yes | yes | yes (with `--pro` login) | n/a — web app |
| Backup automated | yes (sidecar) | yes (sidecar) | yes (sidecar) | n/a — managed |
| Cost | $0 | $0 (free tier limits) | $0 (free tier limits) | from $15/dev/month |
| Hardware footprint | ≥16 GB RAM, GPU ideal | ≥8 GB RAM, GPU ideal for LLM | ≥8 GB RAM | minimal (browser) |
| Network calls | none | embeddings to api.kvendra.com | embeddings to api.kvendra.com | all to kvendra.cloud |
| Quality drift vs SaaS | possible | none (same embeddings) | none | n/a |

Tier C is **NOT** this stack — it's the managed SaaS at
[kvendra.com/enterprise](https://kvendra.com/enterprise). It's listed
here only so the matrix is honest about all four options.

## Tier B — fully self-hosted local

Everything on your machine. Zero outbound network calls beyond what
Ollama needs to fetch model weights the first time.

```dotenv
# .env
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=http://kvendra-ollama:11434/v1
EMBEDDINGS_MODEL=mxbai-embed-large
# No EMBEDDINGS_API_KEY needed for local Ollama.

# OLLAMA_MODELS_PRELOAD pulls these on first ./scripts/up.sh
OLLAMA_MODELS_PRELOAD=llama3.1:8b,mxbai-embed-large
```

Caveats:

- Vectors are produced by `mxbai-embed-large`. If you later switch to
  Tier A you need to **re-embed** the corpus — vectors are not portable
  across embedding models. This is a property of embeddings, not a
  Kvendra limitation.
- Quality drift is possible if you change Ollama embedding model later.
- LLM responses depend on the local model. Llama 3.1 8B is the baseline
  for which the community skills are tuned; other models may need
  variant overlays from `KvendraAI/skills`.

## Tier A — hybrid L1 (embeddings via kvendra.cloud)

Embeddings come from `api.kvendra.com` (free tier, currently 200,000
tokens/month/user). LLM still runs locally via Ollama. Best balance of
SaaS alignment + local privacy of conversations.

```dotenv
# .env
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=https://api.kvendra.com/v1
EMBEDDINGS_MODEL=kvendra-embedding-v1
EMBEDDINGS_API_KEY=<your-key-from-app.kvendra.cloud>

OLLAMA_MODELS_PRELOAD=llama3.1:8b
```

You can skip pulling `mxbai-embed-large` since embeddings come from the
cloud. Saves ≈1.2 GB of model weights locally.

Caveats:

- Network dependency: if `api.kvendra.com` is down, `entity_create` and
  `entity_search` fail until restored.
- You're sharing your **text prompts** for embedding generation with
  the cloud (not your full conversation — only the strings being
  embedded). The kvendra-cloud free tier privacy policy applies.

## Hybrid L2 — Tier A + CLI on Pro

Same as Tier A plus the CLI on your host runs `kvendra login --pro`
which lets you backup and sync between machines. The stack itself is
identical to Tier A; what changes is what the CLI does on your host.

```dotenv
# .env is identical to Tier A.
```

```bash
# On the host (not in the compose):
kvendra login --pro
kvendra backup     # manual backup to your Kvendra Cloud workspace
kvendra notifs     # see notifications for your account
```

## Switching tiers

You can change tier by editing `.env` and restarting the platform:

```bash
# edit .env, then:
docker compose restart kvendra-platform
```

**Heads-up about re-embedding**: if you switch the **embedding model**
(B → A, or A's model changes), existing vectors in the DB are still
based on the old model. Search results may be incoherent until the
corpus is re-embedded. M2 of `ROAD-KVD-PLATFORM-2EC0AE` will deliver a
`kvendra reindex` command; until then, switching tiers on a populated
DB is a soft caveat.

## What about Bedrock / OpenAI / Voyage / Cohere?

All of them are supported by setting `EMBEDDINGS_BASE_URL` to the
provider's OpenAI-compatible endpoint (Bedrock via
[bedrock-access-gateway](https://github.com/aws-samples/bedrock-access-gateway),
others natively). Just use Tier A / B with a different
`EMBEDDINGS_BASE_URL`. The mock provider and bedrock provider live
elsewhere — see `kvendra-platform/src/embeddings/` and
`ADR-KVD-1823F7` for the Open Core boundary.
