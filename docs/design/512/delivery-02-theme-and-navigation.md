# Entrega 02 + 04: tema aplicado al sitio y una sola navegación

Escrito el 2026-11-19 por Claude Code. Brief: `claude-theme-refactor.es.md`. Commit `1582c3d` en la
rama `task/512-docs-guides-less-text-more-visual`, sobre `0d17804`. Sin push, merge ni despliegue.

## Quién tiene qué

| Parte | Dueño | Estado |
| --- | --- | --- |
| Tema, header, barra lateral, idioma, footer | Claude Code | En `1582c3d` |
| Página de inicio (`index.mdx`, `es/index.mdx`, `components/home/`, `HomeHeroOverride.astro`, la línea `Hero:` de `astro.config.mjs`) | Codex | Sin confirmar en el worktree. El dueño lo decidió el 2026-11-19 al ver que los dos escribían en el mismo worktree |

`1582c3d` no contiene la página de inicio. El inicio confirmado sigue siendo el anterior, que usa
`<SearchStart kind="home" />`; ese valor se mantiene en `SearchStart.astro` para que el árbol
confirmado construya.

## Aplicado al sitio real

| Pieza | Qué hay | Archivo |
| --- | --- | --- |
| Paleta | Marfil, carbón, cobalto, salvia y ocre; claro y oscuro. El tema sigue la elección guardada o, sin ella, el sistema | `src/styles/theme.css` |
| Componentes | Botón principal con sombra desplazada, pestañas con trazo de tinta en la seleccionada, tarjetas, avisos (el de consejo como Post-it con cinta), campos, bloques de código oscuros en ambos temas | `src/styles/theme.css`, `expressiveCode` en `astro.config.mjs` |
| Header | Logo ilustrado; búsqueda que dice "Search" / "Buscar"; versión, GitHub, idioma (solo en páginas traducidas) y tema. Se quitó el cambio Software/Marketing | `Header.astro`, `SiteTitle.astro`, `LanguageSelect.astro` |
| Navegación | Una barra lateral para todos: Start here, How it works, siete áreas, For marketing teams (15 páginas en seis subgrupos), Concepts, Reference. Ninguna URL cambió | `astro.config.mjs`, `src/routeData.ts` |
| Idioma | Una página es española si su archivo existe bajo `es/`. Solo esas muestran el selector, llevan `hreflang` y entran en el sitemap. Las demás `/es/` son copias en inglés con `noindex` y canonical a la inglesa | `src/lib/translated.mjs`, `routeData.ts` |
| Footer | Banner de Kito en cada página, EN/ES, enlaces reales (instalación o "cómo funciona", inicio, comandos, GitHub). Movimiento solo CSS, botón Pausar; quieto con movimiento reducido o sin JavaScript | `components/brand/KitoFooter.astro`, `Footer.astro` |
| Imágenes | Recortes WebP de las hojas aprobadas; la hoja de ornamentos de 1.6 MB ya no se sirve | `components/brand/assets/`, `public/brand/trio.webp` |
| Búsqueda | Sin palabra "ask" y sin puntos de color por pista | `SearchStart.astro`, `src/content/i18n/*.json` |

Solo en la muestra `/design/theme/`: la página de estudio misma (noindex, fuera del sitemap). Ninguna
página la importa.

## Verificación

- `pnpm --dir docs-site build` sobre el árbol de trabajo: 216 páginas, sale 0. Aviso único:
  `Entry docs → 404 was not found`, presente antes de este cambio. No hubo `ENOTFOUND
  api.fontsource.org` en esta máquina; la ruta OG lo puede seguir dando sin red.
- Solo los archivos de `1582c3d`, copiados a un directorio aparte con `pnpm install --offline`: 216
  páginas, sale 0.
- `bash scripts/check.sh`: `117 passed, 0 failed`, sobre el árbol de trabajo antes de separar los
  archivos de Codex.
- `scripts/update-path-test.sh`, `docs-marketing-words-test.sh`, `docs-record-tables-test.sh`: ok.
- HTML construido: `/`, `/es/`, `how-the-tools-connect` y `marketing/tools` en ambos idiomas llevan
  el par `hreflang`; `/es/cli-reference/` lleva `noindex, follow` y canonical a `/cli-reference/`.
  Sitemap: 104 URL, 17 bajo `/es/`, ninguna de `/design/`. Enlaces internos rotos en `dist/`: 0.
- Contraste medido en Chrome en `/`, la guía de instalación, `/cli-reference/`, `/es/marketing/`,
  `/review/secret-guard/` y `/tags/`, ambos temas: el texto más bajo es 4.48–4.51 (descripción de
  tarjeta en claro). Se corrigieron dos fallos encontrados: la línea "From Mexico…" del pie (2.95 en
  claro) y las etiquetas de activación (2.47–2.98 en claro), que ahora miden 5.99–7.18 en claro y
  5.76–7.32 en oscuro.
- 320 px: sin desplazamiento horizontal en las cinco páginas medidas; texto mínimo 12 px (la línea
  del pie). El footer apila texto y Kito sin solaparse.
- Teclado: Tab desde el logo recorre búsqueda, versión, GitHub, idioma y tema con contorno de 3 px.
  Pausar en el footer cambia a "Resume motion", `aria-pressed="true"`, y la animación queda en
  `paused`.
- Movimiento reducido emulado: footer `data-motion="off"`, botón Pausar oculto, animaciones `none`,
  transiciones de tarjetas y botones `0s`.

### Capturas

En `evidence/theme-01/`, de `http://localhost:4321/` servido por este worktree antes del commit.
Muestran el inicio de Claude Code, que Codex está reemplazando.

| Archivo | Ruta | Tamaño | Estado |
| --- | --- | --- | --- |
| `home-en-light-1280-full.jpeg` | `/` | 1280 ancho, página completa | claro |
| `home-es-dark-320-full.jpeg` | `/es/` | 320 a 2x, página completa | oscuro |
| `guide-install-dark-1280x900.jpeg` | `/getting-started/install/` | 1280×900 | oscuro, pestañas y chat |
| `guide-install-light-1280x900-aside.jpeg` | `/getting-started/install/` | 1280×900 | claro, aviso con cinta |
| `marketing-es-light-320x720.jpeg` | `/es/marketing/` | 320×720 a 2x | claro, búsqueda |

## Pendiente

- **Página de inicio:** la de Codex, sin confirmar. Al confirmarla, quitar `'home'` de
  `SearchStart.astro` si ya no se usa.
- **Seguimiento:** entregas 03, 05 y 06 son ahora sub-issues de #512: #520 (onboarding en cinco
  capítulos), #521 (inventario de referencia y traducciones), #522 (preguntar a la documentación con
  respuestas citadas).
- **Etiquetas de la barra lateral en español:** se dejan en inglés a propósito; los grupos llevan a
  páginas en inglés. #521 las traduce cuando sus páginas lo estén.
- **No probado:** lector de pantalla, Safari, Firefox, una visita de alguien ajeno al proyecto.
- **Esperan al dueño:** push, descripción y título del PR 517, promoción de la 0.10.
