# Referencia

[English](reference.md) · [Español](reference.es.md)

[← Agentes y orquestación](agents.es.md) · **Referencia** · [Uso](usage.es.md) · [README](../README.es.md)

## Cómo funciona

```
claude-kit/
  .claude-plugin/        plugin.json + marketplace.json   (entrega /kit-init, /kit-customize, /kit-contribute)
  commands/kit-init.md   el slash command /kit-init
  skills/
    kit-customize/       /kit-customize — agrega/edita/elimina agents, conecta skills/tools, lint, profiles
    kit-contribute/      /kit-contribute — envía agents/skills/profiles/solicitudes upstream como PRs
  profiles/*.json        qué agents/skills/rules/roles/milestones por profile
  templates/             archivos fuente con {{VARS}} + bloques <!-- IF:FLAG -->
    CLAUDE.md.tmpl  kit.config.json.tmpl
    agents/  skills/  rules/  hooks/  settings/
  scripts/
    init.sh              motor de sustitución + condicionales (soporta --dry-run)
    lib/kit-config.sh    carga .claude/kit.config.json -> env KIT_* (lo usan las skills)
    lib/gh-project.sh    helpers GraphQL de Projects v2
    setup-labels.sh  setup-milestones.sh  capture-project-ids.sh  task-sync.sh
```

`init.sh` lee el profile elegido, sustituye los valores del proyecto en los templates, resuelve los
bloques `<!-- IF:MEMORY -->` / `IF:PROJECTS_V2` / `IF:PLANS` / `IF:DESIGN`, y escribe un `.claude/`
autocontenido en el destino. Las skills leen los valores vivos del proyecto desde
`.claude/kit.config.json` en tiempo de ejecución, así hay una sola fuente de verdad por proyecto.

## Qué es configurable por proyecto

`.claude/kit.config.json` lleva cada valor específico del proyecto:

- `project` — name, slug, owner, language
- `github` — repo, owner, Projects v2 on/off + número de board
- `roles`, `milestones` — del profile, editables
- `plans` — formato (`mdx` / `markdown` / `none`) + directorio
- `memory` — MemPalace on/off + wing
- `local` — capa de modelo local on/off + puerto + modelo (ver abajo)

## Stack skills autoactivables (convenciones de build)

Las convenciones de build **no** son rules obligatorias — son skills que **se autoactivan solo cuando
su tecnología se detecta en el `package.json` del proyecto**:

| Skill | Se activa cuando | Cubre |
| ----- | ---------------- | ----- |
| `feature-build-refine` | está `@refinedev/*` | arquitectura de feature/form/page con Next.js + Supabase + RefineDev |
| `supabase-patterns` | está `@supabase/supabase-js` | modelo de tres clientes, guard de auth en server actions, acceso RLS-first |

Si la tecnología no está en el stack, la skill simplemente no aplica. Agrega más de la misma forma —
una skill autoactivable por tecnología. Nada se impone de manera global.

## Spec-Driven Development (opt-in)

Actívalo con `--speckit on` (o en el prompt de `/kit-init`). La skill `speckit` instala o identifica
[Spec Kit](https://github.com/github/spec-kit), corre una Stack Interview y conduce el ciclo
`specify → clarify → plan → tasks → analyze → implement` con compuertas de revisión. Cualquier stack
skill que coincida se vuelve automáticamente el override `feature-module.md` de Spec Kit.

## Capa de modelo local (opt-in)

Corre los chores NL del kit — digerir, resumir, clasificar, redactar — en un **modelo local** a
$0 de API, vía el stack MLX de Apple. Cualquier agente/hook hace source de
`scripts/lib/kit-local.sh` y llama `kit_local_chat "<system>" "<prompt>"`; si el server está caído
la llamada devuelve no-cero y el caller usa su camino normal (nunca bloquea, alive-check de 1s).

El camino fácil: actívalo en el init con **`/kit-init --local on`** — escribe el bloque `.local`
del config, scaffoldea el hook de status de SessionStart y lista el comando de setup en los next
steps. **`kit-doctor`** después deja la capa lista de punta a punta (#313): verifica Apple silicon,
instala `mlx-lm` vía `uv tool install` (venv aislado, PEP 668-safe; fallback `pipx` — nunca
`pip` directo, que falla contra el python externally-managed de Homebrew), y levanta
`mlx_lm.server` en background con health check del puerto (la primera corrida descarga el
modelo, ~4.5 GB). `--dry-run` es 100% read-only. Con la capa activada pero caída, cada inicio
de sesión imprime un aviso hasta que suba o lo descartes (`kit-doctor --dismiss-local`, o
`KIT_LOCAL_DISMISS=1`); el dismiss dura hasta el siguiente update x.y del kit.

Setup manual (Apple silicon):

```bash
uv tool install mlx-lm   # fallback: pipx install mlx-lm
mlx_lm.server --model mlx-community/Qwen3-8B-4bit --port 8080
```

O actívalo después en `.claude/kit.config.json` (y corre `/kit-init --upgrade --local on` para
agregar el hook):

```json
"local": { "enabled": true, "port": 8080, "model": "mlx-community/Qwen3-8B-4bit" }
```

Con el server vivo, el hook SessionStart `kit-local-status.sh` imprime una línea de banner
(`local: Qwen3-8B-4bit viva @ :8080`) — el silencio significa que la capa está apagada. Las env
vars `KIT_LOCAL_ENABLED`, `KIT_LOCAL_PORT`, `KIT_LOCAL_MODEL`, `KIT_LOCAL_TIMEOUT` ganan sobre el
config. El modelo default necesita ~5 GB de RAM; usa uno menor (p. ej. `Qwen3-4B-4bit`) en
máquinas más justas.

## Pre-push gate (opt-in)

Actívalo con `--prepush "<comando>"` en el init (p. ej. `--prepush "pnpm -w build"`). Instala un hook
`PreToolUse(Bash)` que corre `<comando>` antes de cada `git push` y **bloquea el push si el comando
falla**. Es **autopasante**: solo actúa sobre `git push`, y los proyectos que no lo activan (o tienen
el comando vacío) nunca se bloquean. Configurable después vía `.prePush` en `.claude/kit.config.json`.

## Requisitos

- `gh` (autenticado), `jq`, `perl`, `git`, bash 3.2+ (el bash de sistema de macOS sirve)
- `/kit-init` corre un **setup de herramientas opt-in** durante el onboarding — para cada herramienta
  explica el propósito e instala/autentica solo con tu consentimiento:
  - **`gh`** — verifica `gh auth status` y ofrece `gh auth login` (requerido para el workflow de tareas/PR)
  - **MemPalace** — solo si activas la memoria; registra el MCP `mempalace` o guía la instalación del
    runtime `mempalace-mcp`. La memoria queda inactiva (nunca da error) hasta que esté presente.
  - **`gws`** (Google Workspace CLI) — solo si trabajas con Google Docs/Sheets/Slides/Drive/Gmail;
    ofrece `gws auth login`. Si no, se omite.

## Atribución

`karpathy-guidelines` se incorpora (MIT) desde
[multica-ai/andrej-karpathy-skills](https://github.com/multica-ai/andrej-karpathy-skills)
(© forrestchang), derivado de las notas de Andrej Karpathy sobre errores comunes de LLM al programar.
