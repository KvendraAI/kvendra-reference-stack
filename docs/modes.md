<!-- SPDX-License-Identifier: MIT -->

# Operating modes

The Kvendra Self-Hosted Community stack is **one set of containers** but
**three possible operating modes**, selected via the `EMBEDDINGS_*` env
vars and (for Ollama) a docker compose profile. They trade off privacy
vs alignment with the SaaS vs ops simplicity. The default is **Cloud
embeddings** — easiest path for someone who just signed up at
`https://kvendra.cloud`.

## At a glance

| Aspect | Cloud (default) | Ollama (opt-in) | Mock (CI / dev) |
|---|---|---|---|
| Embeddings | `api.kvendra.cloud` (free tier) | Local Ollama (`mxbai-embed-large`) | Deterministic test vectors |
| LLM | Whatever your orchestrator uses (Claude Code → Anthropic; or local Ollama) | Local Ollama | n/a |
| Containers started | 3 (db + platform + backup) | 4 (db + platform + ollama + backup) | 3 (db + platform + backup) |
| Cost | $0 (free tier, 200k tok/month) | $0 | $0 |
| Hardware footprint | ≥4 GB RAM, no GPU needed | ≥16 GB RAM, GPU recommended | ≥4 GB RAM |
| Network calls | embeddings to `api.kvendra.cloud` | none (after model pulls) | none |
| Privacy of embedded text | sent to `api.kvendra.cloud` | stays on your machine | n/a |

The managed SaaS at [kvendra.com/enterprise](https://kvendra.com/enterprise)
is a **separate product**, not a mode of this stack — listed elsewhere
in the docs for completeness.

## Cloud (default)

Embeddings come from `api.kvendra.cloud` (free tier currently 200,000
tokens/month/user). No Ollama container is started. Best path if you
want the fastest setup and don't mind sending the strings being embedded
to Kvendra Cloud (your full conversation never leaves — only the
embedding input strings).

```dotenv
# .env (already the default in .env.example)
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=https://api.kvendra.cloud/v1
EMBEDDINGS_MODEL=kvendra-embedding-v1
EMBEDDINGS_API_KEY=REPLACE_WITH_YOUR_KVENDRA_KEY
```

Signup steps:

1. Sign up at [https://kvendra.cloud](https://kvendra.cloud) (free tier).
2. Generate an API key from the dashboard.
3. Paste it into `.env` replacing `REPLACE_WITH_YOUR_KVENDRA_KEY`.
4. `./scripts/up.sh` — `up.sh` will warn you if the placeholder is still
   present.
5. (Optional) `./scripts/smoke-cloud.sh` to verify the key reaches the
   embeddings endpoint and returns a 1024-dim vector.

Caveats:

- Network dependency: if `api.kvendra.cloud` is unreachable,
  `entity_create` and `entity_search` fail until restored.
- You're sharing your **text prompts** for embedding generation with
  Kvendra Cloud. The free-tier privacy policy applies.

## Ollama (opt-in)

Everything on your machine. Zero outbound network calls beyond what
Ollama needs to fetch model weights the first time. Start the stack with
the `ollama` profile so the `kvendra-ollama` container is created:

```bash
./scripts/up.sh --with-ollama
```

That's it — **no manual `.env` editing needed**. The `--with-ollama`
flag does two things for you:

1. Starts the `kvendra-ollama` container (equivalent to
   `docker compose --profile ollama up -d`).
2. Rewires the embeddings env vars in `.env` so the platform points at
   the local Ollama container instead of `api.kvendra.cloud`.

After `--with-ollama`, `.env` will contain (rewritten in place,
idempotently, with a marker comment):

```dotenv
# .env — set by up.sh --with-ollama
EMBEDDINGS_PROVIDER=openai-compatible
EMBEDDINGS_BASE_URL=http://kvendra-ollama:11434/v1
EMBEDDINGS_MODEL=mxbai-embed-large
# EMBEDDINGS_API_KEY is left as-is but unused for local Ollama.
```

The embeddings model is pulled on the first `--with-ollama` run via
`OLLAMA_MODELS_PRELOAD` (default `mxbai-embed-large`). If you also want a
local LLM, append it (e.g. `OLLAMA_MODELS_PRELOAD=mxbai-embed-large,llama3.1:8b`).

> If you'd rather wire it by hand (or use a different local model),
> setting these three vars yourself produces the same result — the
> script detects an existing definition and does not duplicate it.

Caveats:

- Vectors are produced by `mxbai-embed-large`. If you later switch to
  Cloud you need to **re-embed** the corpus — vectors are not portable
  across embedding models. This is a property of embeddings, not a
  Kvendra limitation.
- LLM responses depend on whatever your orchestrator uses. Llama 3.1 8B
  is the baseline against which the canonical skills are tuned; other
  models may need adjustments.

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

Search results in this mode are non-semantic (the mock returns the same
vector for any input). Don't use it for real work.

## Switching modes

You can change mode by editing `.env` and restarting the platform:

```bash
# edit .env, then:
docker compose restart kvendra-platform
```

If you also need to add or remove the `kvendra-ollama` container, take
the whole stack down and bring it back up with (or without) the profile:

```bash
docker compose down
./scripts/up.sh --with-ollama     # or just ./scripts/up.sh
```

Re-running with `--with-ollama` also (re-)applies the Ollama embeddings
wiring in `.env` for you, so this is the one command needed to switch
onto local Ollama — no manual edit. To go back to Cloud, edit the three
`EMBEDDINGS_*` lines back (and remove the `# set by up.sh --with-ollama`
marker) before `./scripts/up.sh` without the flag.

**Heads-up about re-embedding**: if you switch the **embedding model**
(Cloud ↔ Ollama, or the Ollama model changes), existing vectors in the
DB are still based on the old model. Search results may be incoherent
until the corpus is re-embedded. M2 of `ROAD-KVD-PLATFORM-2EC0AE` will
deliver a `kvendra reindex` command; until then, switching modes on a
populated DB is a soft caveat.

## What about Bedrock / OpenAI / Voyage / Cohere?

All of them are supported by setting `EMBEDDINGS_BASE_URL` to the
provider's OpenAI-compatible endpoint (Bedrock via
[bedrock-access-gateway](https://github.com/aws-samples/bedrock-access-gateway),
others natively). Just use the same `openai-compatible` provider with a
different `EMBEDDINGS_BASE_URL`. The mock provider and the bedrock
provider live elsewhere — see `kvendra-platform/src/embeddings/` and
`ADR-KVD-1823F7` for the Open Core boundary.

## Skill variants for non-Claude-Code IDEs

Skill variants for non-Claude-Code IDEs live in
[`KvendraAI/kvendra-skills`](https://github.com/KvendraAI/kvendra-skills)
(Apache-2.0). They're community-maintained and lag behind the canonical
set that ships with Claude Code (see PAT-KVD-4AF89B for the rationale
behind Claude Code as the universal orchestrator).
