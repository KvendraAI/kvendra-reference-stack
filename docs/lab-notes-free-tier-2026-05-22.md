# Free tier Kvendra — lab notes del E2E spike (2026-05-21/22)

> **Disclaimer**: esto es **un informe de un test de concepto**, no un
> manual oficial ni una recomendación de despliegue. Lo escribimos para
> documentar lo que se probó y bajo qué condiciones, de manera que la
> comunidad pueda **reproducir el experimento** y formarse su propia
> opinión sobre si esta vía les sirve.
>
> El test corrió en una máquina **pequeña** (T4 de un g4dn.xlarge) con
> un **LLM relativamente pequeño** (mistral-small3.1:24b cuantizado).
> La experiencia de usuario puede ser **lenta** y las respuestas
> requieren prompts cuidadosos. Para uso serio, recomendaríamos
> hardware mayor (≥24 GB VRAM) o un LLM cloud (Anthropic Claude API,
> OpenAI, etc.).

## Por qué publicamos esto

Queríamos saber, antes de prometer nada a la comunidad, si la pila
Kvendra puede correr **de extremo a extremo en modo self-hosted free**:
docker stack + Ollama LLM + Ollama embeddings + skills + MCP, sin
cuenta Anthropic, sin cuenta Kvendra, sin AWS. La respuesta corta es
**sí, es viable** — pero hay caveats que importan. Este doc lista lo
que se hizo y lo que pasó, para que cualquiera pueda repetirlo.

## Hardware del lab

- EC2 `g4dn.xlarge` en `eu-west-1` (instancia Winking Owl mientras la
  cuenta Kvendra tenía quota 0 en G/VT).
- 4 vCPU, 16 GiB RAM total, GPU NVIDIA Tesla T4 con **16 GB VRAM**,
  disco EBS 150 GB.
- AMI `Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)`,
  driver NVIDIA 580.159.03, CUDA 12.9 disponible (otras 12.6 / 12.8 /
  13.0).
- Coste de la prueba: ~$0.526/h on-demand, total ≈ $4 por las 7-8h del
  spike.

T4 es una GPU de inferencia barata, lo más asequible con CUDA capable
en la nube. Sirve para validar concepto pero **no es ideal para uso
diario** con modelos 20B+.

## Software stack

| Componente | Versión probada | Función |
|---|---|---|
| Docker Engine + NVIDIA Container Toolkit | 24+ | GPU passthrough via `deploy.resources.devices` |
| Ollama | 0.24.0 | Soporta Anthropic Messages API nativo desde 0.14.0 |
| Postgres + pgvector | `pgvector/pgvector:pg16` | KB storage + vector search |
| kvendra-platform | 0.1.0-alpha.0 (AGPL) | Motor MCP server |
| LLM probado | `mistral-small3.1:16k` (24B Q4, num_ctx=16384, ~15 GB VRAM) | Generación + tool calling |
| Embedder | `mxbai-embed-large` (1024-dim, L2-normalised, ~700 MB) | Vector embeddings |
| Node.js | v22.22.3 vía nvm | Runtime para Claude Code |
| Claude Code | 2.1.147 (`@anthropic-ai/claude-code`) | Agente CLI con tool calling nativo + MCP support |
| Skills | `KvendraAI/skills` (4 skills: init, explore, fix-simple, summarize) | UX layer sobre las MCP tools |

## Pasos concretos del experimento

Para reproducirlo necesitas Docker + nvidia-container-toolkit + Node 22
en una máquina con GPU NVIDIA. El orden que seguimos:

### 1. Arrancar el stack docker

```bash
git clone https://github.com/KvendraAI/kvendra-reference-stack
cd kvendra-reference-stack
./scripts/up.sh    # postgres + platform + ollama + backup
curl http://localhost:7777/healthz   # 200 OK confirma motor vivo
```

El stack genera `data/auth.token` automáticamente (Bearer token para
el MCP server).

### 2. Pullear modelos en Ollama

El embedder se pulla solo. El LLM se pulla manualmente:

```bash
docker exec kvendra-ref-ollama ollama pull mistral-small3.1

# Variante con num_ctx 16K — necesaria porque el system prompt de
# Claude Code es ~5-8 KB tokens
cat > /tmp/Modelfile-16k <<EOF
FROM mistral-small3.1:latest
PARAMETER num_ctx 16384
EOF
docker cp /tmp/Modelfile-16k kvendra-ref-ollama:/tmp/
docker exec kvendra-ref-ollama ollama create mistral-small3.1:16k -f /tmp/Modelfile-16k
```

Con num_ctx=16K el modelo ocupa **~14.5 GB VRAM**, casi todo el T4.
Probamos también `num_ctx=32K` y no cupo (OOM partial offload). En una
RTX 4090 o A10G de 24 GB cabría con margen.

### 3. Instalar Claude Code

```bash
nvm install 22
npm install -g @anthropic-ai/claude-code
claude --version    # 2.1.147 en nuestro test
```

### 4. Configurar Claude Code para hablar con Ollama

`~/.claude/settings.json`:

```json
{
  "apiKeyHelper": "echo ollama",
  "env": {
    "ANTHROPIC_BASE_URL": "http://localhost:11434",
    "ANTHROPIC_API_KEY": "ollama",
    "ANTHROPIC_AUTH_TOKEN": "ollama",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "mistral-small3.1:16k",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "mistral-small3.1:16k",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "mistral-small3.1:16k"
  }
}
```

- `apiKeyHelper` devuelve una string no-vacía → Claude Code considera
  al user "autenticado" sin OAuth contra Anthropic.
- `ANTHROPIC_BASE_URL` apunta a Ollama, que habla Anthropic Messages
  API nativo desde 0.14.0.
- `ANTHROPIC_DEFAULT_*_MODEL` cubre las tres categorías que Claude Code
  despacha internamente (todas mapeadas al mismo modelo local).

### 5. Registrar el MCP server kvendra-platform en Claude Code

Desde el cwd de tu proyecto:

```bash
TOKEN=$(cat /home/ubuntu/kvendra-reference-stack/data/auth.token)
claude mcp add --transport http kvendra-platform http://localhost:7777/mcp \
  --header "Authorization: Bearer $TOKEN"
claude mcp list
# kvendra-platform: http://localhost:7777/mcp (HTTP) - ✓ Connected
```

### 6. Instalar los community skills

```bash
mkdir -p .claude/skills
git clone --depth 1 https://github.com/KvendraAI/skills /tmp/kvd-skills
cp -r /tmp/kvd-skills/skills/* .claude/skills/
# explore  fix-simple  init  summarize
```

## Qué se probó y qué pasó

### Prueba A — entity_create directo

Prompt imperativo:
```
Use the mcp__kvendra-platform__entity_create tool with these arguments:
entity_type=PRJ, entity_id=PRJ-MYTEST, title=MyTest, project_id=MYTEST.
Then reply: Created PRJ: <entity_id>
```

Resultado: ✅ funcional. Mistral emite `tool_use` correcto, Claude Code
lo ejecuta contra el MCP server, la entity se persiste en KB con
embedding real de 1024d. Tiempo total: ~12 s (de los cuales ~9 s son
embedding cold-load la primera vez; subsiguientes ~1 s).

### Prueba B — skill `/init <Project>`

Prompt: `/init AcmeWeb`

Resultado: ✅ funcional. El skill se resuelve, mistral emite `tool_use`
con los placeholders sustituidos, entity persistida. La respuesta del
LLM sale en el formato exacto del skill: `Created PRJ: PRJ-ACMEWEB`.

### Prueba C — multi-step narrativo en un solo prompt

Prompt: `Initialize a Kvendra project for this repository called AcmeWeb. After creating the PRJ, read README.md and give me a 3-bullet summary.`

Resultado: ⚠️ inconsistente. Mistral planifica los pasos en texto
("voy a hacer A, luego B, luego C") pero a veces no llega a emitir el
`tool_use` real para alguno de los pasos. Con el mismo prompt en
Claude Sonnet/Opus (via API) sí completaría sin problema; con mistral
24B en T4 ~50% del tiempo se queda en "describir el plan".

Workaround práctico para usuarios Free: invocar skills uno a uno con
prompts directos en turnos separados.

### Prueba D — onboarding sobre repo grande (kvendra-reference-stack)

Lanzar `claude -p "init + explore..."` sobre el repo entero del
reference-stack (~100 ficheros, CLAUDE.md, sources/, scripts/, docs/).

Resultado: ❌ se cuelga o timeout. Razón probable: Claude Code escanea
el cwd y genera mucho contexto auto-inyectado; sumado al system prompt
+ 14 MCP tools + 4 skills se supera el num_ctx de 16K del modelo,
mistral truncate y deja de procesar. En sample-project mínimo (3
archivos) sí funcionó.

## Modelos LLM evaluados durante el spike

Probamos varios para entender qué se puede esperar de modelos locales
en una T4:

| Modelo | Tamaño | Con cline-cli | Con Claude Code + Ollama | Resumen |
|---|---|---|---|---|
| `mistral-small3.1:16k` | 24B Q4, ~15 GB | ❌ describe JSON | ✅ funciona con prompts directos | El más estable de los locales probados |
| `gpt-oss:20b` | 20B Q4, ~13 GB | n/a | ❌ alucina/responde fuera de tema | No usar en este flow |
| `hhao/qwen2.5-coder-tools:14b` | 14B Q4, ~9 GB | ❌ JSON en markdown | n/a | Fine-tuned para Roo-Code, no para cline-cli |
| `maryasov/llama3.1-cline:8b` | 8B Q8, ~8.5 GB | ❌ XML parcial + CDATA | n/a | Fine-tuned para versión antigua de cline |
| `mistral-small3.1` vanilla | 24B Q4 | n/a | ❌ context overflow con num_ctx default 4K | Usar variante 16k |
| `qwen2.5:14b-16k` | 14B Q4, ~9 GB | ❌ tool calls malformados | n/a | — |
| `llama3.1:8b` | 8B Q4, ~5 GB | ❌ alucina pseudocódigo | n/a | — |
| `gemma3:4b` | 4B, ~3 GB | ❌ no soporta `tools` | ❌ idem | — |
| `qwen3-coder` | 30B, ~18 GB | n/a | n/a — **no cabe en T4** | Requeriría ≥24 GB VRAM |

**Conclusión**: con T4 y un LLM ≤24B, **Claude Code + Ollama + Mistral
24B + prompts directos** fue la única combinación en la que llegamos
consistentemente a entidad creada en KB. Las otras o no caben, o el
modelo no emite tool calls compatibles, o el cliente (cline) no se
entiende con el modelo local.

## Caveats honestos

1. **La experiencia es lenta**: ~30s primer turno (cold-load), ~10-15s
   por turno subsiguiente, embedding cold-load otros ~20s. Comparado
   con Claude Sonnet via API (~3-5s un turn entero), es un orden de
   magnitud más lento.

2. **Prompts directivos > narrativos**: con mistral 24B local, prompts
   imperativos cortos ("Use tool X with args Y NOW") funcionan; prompts
   conversacionales largos (multi-step en una sola frase) son
   inconsistentes. Esto NO pasa con Claude API.

3. **Hardware mínimo realista**: T4 16 GB fue justo. Para uso diario
   recomendaríamos RTX 4090 / A10G / similar con ≥24 GB VRAM, que
   permite num_ctx 32K y/o modelos algo mayores.

4. **RAM del host también cuenta**: con 16 GiB total, cargar dos
   modelos seguidos llenó buff/cache y dio OOM. Hay que limpiar
   manualmente: `sudo sync && sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches'`.

5. **Pricing display en Claude Code muestra $0**: esto es esperado, no
   un bug. Los tokens se procesan localmente, no facturados contra
   Anthropic.

6. **No esperar paridad con Pro/Cloud**. Skills complejos, chains
   multi-step, autocorrección sobre errores: todo funciona
   sustantamente mejor con Claude Sonnet/Opus via API que con cualquier
   LLM local de 8-24B parámetros. Este test demuestra **viabilidad
   técnica**, no equivalencia.

## Lo que validamos al final

El motor Kvendra (Mode 02 Self-hosted) **funciona end-to-end en local
y gratis**:

- ✅ Stack docker reproducible.
- ✅ MCP server estándar Streamable HTTP (post-fix de un bug del
  transport descubierto durante este spike; ver
  `ISSUE-KVD-PLATFORM-98C2AA`).
- ✅ Embeddings semánticos reales locales (1024d L2-norm via Ollama).
- ✅ Claude Code como agente con tool calling robusto, sin cuenta
  Anthropic, conectándose a Ollama via Anthropic Messages API nativo.
- ✅ Skills `init`, `explore`, `fix-simple`, `summarize` cargables y
  ejecutables.
- ✅ Entities reales persistidas en KB con embedding real.

Lo que **no garantizamos** y donde explícitamente desaconsejamos
prometer paridad con Pro:

- Multi-step complejo en prompts narrativos con LLM local ≤24B.
- Onboarding "magic one-shot" sobre repos grandes.
- Tiempos de respuesta competitivos con Anthropic API.

Para producción/uso diario, la recomendación honesta es **Mode 01
Cloud** (Pro+) o **Mode 03 Hybrid** (Free local + cloud embeddings).
Mode 02 Self-hosted free es para usuarios que valoran privacidad
total + cero coste por encima de velocidad/comodidad, y que están
dispuestos a operar el stack.

## Referencias y links

- Stack docker reproducible: `KvendraAI/kvendra-reference-stack`.
- Motor MCP (AGPL): `KvendraAI/kvendra-platform`.
- Community skills (Apache-2.0): `KvendraAI/skills`.
- Claude Code: docs en `https://docs.anthropic.com/en/docs/claude-code`.
- Ollama Anthropic compat: `https://ollama.com/blog/claude` (2026-01-16).
- Bugs descubiertos durante el spike y corregidos:
  - `ISSUE-KVD-PLATFORM-98C2AA` — MCP transport `GET /mcp` ignoraba
    `Accept: text/event-stream` (RESOLVED, commit `5db0c46`).
  - `ISSUE-KVD-SKILLS-BE4A0F` — cline-cli 3.0.9 + Ollama LLM local
    skill orchestration no production-ready (OPEN, workarounds
    documentados, este DOC describe la alternativa que sí funciona).

## Cómo contribuir

Si reproduces este experimento y encuentras mejoras, abre un PR o
issue en el repo correspondiente. En particular nos interesan:

- Modelos open-source nuevos que mejoren el tool calling local en
  hardware ≤16 GB VRAM.
- Patrones de prompting que hagan multi-step más robusto con LLM
  locales.
- Skills nuevos en `KvendraAI/skills` que complementen los 4 base.

Este lab es solo un punto de partida.
