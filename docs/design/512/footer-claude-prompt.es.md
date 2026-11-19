# Continuar el footer y el tema de cckit

Trabaja en el worktree existente de #512 y lee su estado antes de actuar. Respeta AGENTS.md y
las reglas locales; aplica concrete a la prosa durable. No descartes cambios sin commit.

José aprobó explorar el lenguaje editorial de Kito. La muestra actual está en `/design/theme/`,
implementada en `docs-site/src/pages/design/theme.astro`. Esta tarea continúa esa implementación;
no reinicies el diseño ni lo sustituyas por componentes genéricos.

El footer ya existe en `docs-site/src/components/brand/KitoFooter.astro`, en ambos temas.
Reutiliza la lámina `brand/assets/ornaments.png`, la imagen `learning/assets/kito-pointing.png`
y `brand/StickerLogo.astro`. El logo del header es la variante ilustrada cckit de la referencia,
no un wordmark inventado con asterisco ni un sticker tipográfico colocado en el hero.
Los personajes se llaman Nota (Post-it), Kito (terminal) y Memo (USB). Sus nombres bajo el trío
son pequeños y discretos, según la última corrección de José.

## Qué conservar

- Papel marfil, tinta verde carbón, cobalto, salvia y ocre. Geist y Geist Mono.
- Composición editorial con espacio, bordes finos y offsets selectivos. Puntos, flechas,
  subrayados y destellos de la lámina original como acentos, sin llenar cada superficie.
- Footer con una invitación breve, Kito, una nota flotante y enlaces reales a la guía,
  referencia de comandos y GitHub. Nada de listas extensas o texto técnico en el banner.
- Movimiento sutil mediante transform y un trazo punteado animado. El botón de pausa debe
  detener todas las animaciones decorativas; movimiento reducido y ausencia de JavaScript
  deben dejar una composición estática legible.

## Siguiente trabajo

Revisa la muestra en escritorio y a 320px en claro/oscuro. Comprueba que el banner se reorganiza
sin solapar el texto o cortar la llamada principal, que los enlaces llevan a destinos reales,
que el foco es visible y que pausa/reanudar funciona con teclado. Revisa movimiento reducido.
Mantén los detalles decorativos fuera del árbol accesible y las acciones dentro del HTML real.

El footer se revisó visualmente en el navegador en escritorio, en ambos temas; se probó el botón
de pausa en el claro y mostró Reanudar movimiento. Esto no equivale a probar móvil, lectores de
pantalla o Safari/Firefox. No presentes comprobaciones pendientes como aprobadas.

El build completo anterior se bloqueó en la descarga de la fuente de una ruta OG existente
(`ENOTFOUND api.fontsource.org`). El estudio se compila aparte con las dependencias existentes;
no añadas paquetes para corregir ese bloqueo de red. Registra el resultado actual del build.

Tras validar la composición, prepara su integración en el sitio unificado dentro del alcance
documentado en `docs/design/512/`. La revisión del contenido de entrada sigue sus propios briefs:
este footer no aprueba la antigua página verbosa ni autoriza replicarla.
No hagas push, merge ni despliegue. Deja archivos modificados, comprobaciones reales, pendientes
y `cckit handoff` para continuar.

Prosa revisada: O13, se distingue revisión visual de validación pendiente; O14, se continúa la
muestra existente y se prepara su integración, sin afirmar que el tema global ya esté aprobado.
