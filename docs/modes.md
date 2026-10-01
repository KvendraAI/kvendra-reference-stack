<!-- SPDX-License-Identifier: MIT -->

# Operating modes

The Kvendra Self-Hosted Community stack is **one set of containers**
with **two built-in embeddings modes**, plus the option to point it at
**your own provider**. The mode is selected via the `EMBEDDINGS_*` env
vars in `.env`. The default is **local Ollama** — no account, no API
key, nothing leaves your machine.

## At a glance

| Aspect | Ollama (default) | Your own provider | Mock (CI / dev) |
|---|---|---|---|
| Embeddings | Local Ollama (`mxbai-embed-large`, 1024-dim) | Any OpenAI-compatible endpoint serving a 1024-dim model | Deterministic test vectors |
| Start command | `./scripts/up.sh` | `./scripts/up.sh --no-ollama` | `./scripts/up.sh --no-ollama` |
| Containers started | 4 (db + platform + ollama + backup) | 3 (db + platform + backup) | 3 (db + platform + backup) |
| Account / API key | none | your provider's | none |
| Hardware footprint | ≥8 GB RAM for embeddings only, no GPU needed | ≥4 GB RAM | ≥4 GB RAM |
| Network calls | none (after the first model pull) | embeddings to your provider | none |
| Privacy of embedded text | stays on your machine | sent to your provider | n/a |

The LLM is whatever your orchestrator uses (Claude Code → Anthropic, or
a local model) — it is independent of the embeddings mode.

The managed SaaS at [kvendra.com/enterprise](https://kvendra.com/enterprise)
is a **separate product**, not a mode of this stack — listed elsewhere
in the docs for completeness.

## Ollama (default)

Everything on your machine. Zero outbound network calls beyond what
Ollama needs to fetch model weights the first time.

```bash
cp .env.example .env
./scripts/up.sh
```

`.env.example` already points the platform at the local container:

```dotenv
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=http://kvendra-ollama:11434/v1
EMBEDDINGS_MODEL=mxbai-embed-large
EMBEDDINGS_API_KEY=
```

`up.sh` starts the `kvendra-ollama` container and pulls the models
listed in `OLLAMA_MODELS_PRELOAD` (default `mxbai-embed-large`). If you
also want a local LLM, append it (e.g.
`OLLAMA_MODELS_PRELOAD=mxbai-embed-large,llama3.1:8b`).

Verify end to end (create + semantic search):

```bash
./scripts/smoke.sh
```

> `--with-ollama` is still accepted by `up.sh` for older instructions,
> but it has no effect: Ollama is the default.

## Your own OpenAI-compatible provider

Point the platform at any endpoint that follows the OpenAI
`/v1/embeddings` shape. **The Platform validates 1024-dim vectors and
does not send a `dimensions` parameter**, so pick a model that is
natively 1024-dim:

- vLLM or Hugging Face TEI serving `mxbai-embed-large` or `bge-large-en-v1.5`
- Mistral `mistral-embed`
- a gateway (e.g. LiteLLM, or
  [bedrock-access-gateway](https://github.com/aws-samples/bedrock-access-gateway)
  for Bedrock Titan v2) that pins the output to 1024 dimensions

Models that default to another size (e.g. OpenAI `text-embedding-3-*`)
only work behind such a gateway.

```dotenv
# .env
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=https://your-provider.example.com/v1
EMBEDDINGS_MODEL=mxbai-embed-large
EMBEDDINGS_API_KEY=your-provider-key
```

Then start the stack without the Ollama container and run the smoke
test:

```bash
./scripts/up.sh --no-ollama
./scripts/smoke.sh
```

Caveats:

- Network dependency: if your provider is unreachable, `entity_create`
  and `entity_search` fail until it is back.
- The strings being embedded (entity titles/content and search queries)
  are sent to your provider; its privacy terms apply.

## Mock (CI / dev)

Deterministic test vectors, no external calls. Used for CI pipelines or
when you want to prove the platform boots end-to-end without any
embeddings provider configured.

```dotenv
# .env
EMBEDDINGS_PROVIDER=mock
EMBEDDINGS_BASE_URL=
EMBEDDINGS_MODEL=
EMBEDDINGS_API_KEY=
```

Start it with `./scripts/up.sh --no-ollama`. Search results in this
mode are non-semantic. Don't use it for real work.

## Switching modes

Edit the `EMBEDDINGS_*` lines in `.env`, then bring the stack back up
with (or without) Ollama:

```bash
docker compose down
./scripts/up.sh                 # Ollama
./scripts/up.sh --no-ollama     # your own provider / mock
```

If only the provider settings changed (the set of containers is the
same), restarting the platform is enough:
`docker compose restart kvendra-platform`.

### Switching provider = re-embedding

Changing provider **or** model changes the vector space — even when
both produce 1024-dim vectors. Vectors already stored in the DB were
produced by the old model and are not comparable with the new ones, so
search results become incoherent until the corpus is re-embedded.
Re-embed your existing entities after switching (or start from an
empty KB). M2 of `ROAD-KVD-PLATFORM-2EC0AE` will deliver a
`kvendra reindex` command; until then, switching on a populated DB is a
caveat to plan for. This is a property of embeddings, not a Kvendra
limitation.

### Older `.env` files

The hosted Kvendra embeddings endpoint has been retired (2026-10-01).
If your `.env` still points at it, `up.sh` rewrites the `EMBEDDINGS_*`
lines to the local Ollama defaults (marked with
`# set by up.sh (kvendra cloud embeddings retired)`) and reminds you to
re-embed.

The mock provider and the bedrock provider live elsewhere — see
`kvendra-platform/src/embeddings/` and `ADR-KVD-1823F7` for the Open
Core boundary.

## Skill variants for non-Claude-Code IDEs

Skill variants for non-Claude-Code IDEs live in
[`KvendraAI/kvendra-skills`](https://github.com/KvendraAI/kvendra-skills)
(Apache-2.0). They're community-maintained and lag behind the canonical
set that ships with Claude Code (see PAT-KVD-4AF89B for the rationale
behind Claude Code as the universal orchestrator).
