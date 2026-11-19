# Continuar el refactor con la dirección visual aprobada

Continúa el refactor de la documentación de cckit en la rama y el worktree existentes.
Lee AGENTS.md, el estado de cckit y los cambios locales antes de tocar archivos. Conserva el
trabajo ya hecho. Organiza el alcance restante con el flujo de issues/efforts del proyecto.
Aplica concrete a los artefactos durables y deja handoff al terminar o interrumpirte.

## Decisión actual de José

La dirección de `/design/theme/` está aprobada para continuar el refactor: escritorio editorial
de developer, Geist/Geist Mono, marfil, verde carbón, cobalto, salvia y ocre, detalles de tinta,
offset y ornamentos selectivos. Usa la implementación actual como fuente de verdad visual.
La idea de un SaaS/constructor online y de separar los dominios se hará en otro proyecto después
de este refactor. No migres dominios ni construyas ese producto en esta tarea.

## Material existente

- `docs-site/src/pages/design/theme.astro`: muestra de componentes y composición, con dos temas.
- `docs-site/src/components/brand/StickerLogo.astro`: logo ilustrado de la referencia en el header.
- `docs-site/src/components/brand/Ornament.astro` y `brand/assets/ornaments.png`: acentos reutilizables.
- `docs-site/src/components/brand/KitoFooter.astro`: banner animado con enlaces y control de pausa.
- `docs/design/512/`: referencias, historia de contenido, revisiones y límites de validación.

Los personajes son Kito (terminal), Nota (Post-it) y Memo (USB). Conserva los nombres pequeños
bajo cada uno. El logo ilustrado va en el header; el sticker tipográfico temporal del hero se
retiró. No regeneres las referencias ni sustituyas la identidad por otra.

## Trabajo

1. Extrae de la muestra los tokens y componentes necesarios y aplica el tema al sitio real:
   header, navegación, portada, guías, referencia, enlaces, botones, pestañas, código, avisos,
   formularios y footer. La muestra no debe convertirse en una dependencia de las páginas.
2. Integra ornamentos en la jerarquía: subrayados, acentos de acciones, puntos y cinta sobre
   notas. Preserva superficies de lectura limpias, foco visible y estados comprensibles.
3. Conserva el banner del footer, sus destinos reales, movimiento sutil, pausa y alternativa
   estática con movimiento reducido o sin JavaScript. Evita solapes en móvil.
4. Unifica la navegación sin la elección Software/Marketing. Mantén los perfiles del CLI y
   el contenido de marketing como casos de uso. Preserva rutas, referencias y redirecciones.
5. Continúa la reescritura como una historia visual de una app de reservas de servicios.
   Muestra una mejora y su resultado antes de enseñar términos o comandos. La entrada
   rechazada era demasiado verbosa: no propagues sus tarjetas y tablas al resto del sitio.
   La escena revisada de `/learn/` y las últimas revisiones son el punto de partida.
6. Mantén los detalles técnicos en guías y referencia, con prerrequisitos visibles antes de
   ejecutar acciones. No elimines hechos ni los escondas para conseguir un conteo de palabras.
7. Atiende EN/ES, idioma y metadatos según traducciones reales. No anuncies Ask AI mientras
   solo exista búsqueda ni presentes una ilustración como captura de una ejecución real.

## Verificación y cierre

Revisa escritorio y 320px, claro/oscuro, teclado, estados, enlaces, contraste y movimiento
reducido. Ejecuta el build y los checks pertinentes. Separa resultados comprobados de pendientes.
El build completo previo falló descargando la fuente de una ruta OG (`ENOTFOUND api.fontsource.org`);
el build aislado de la muestra sí pasa. Revisa el estado actual sin ocultar fallos por infraestructura.

Trabaja por entregas verificables. Reporta qué quedó aplicado al sitio real y qué sigue solo en
la muestra. Actualiza seguimiento y handoff con comandos/resultados reales. No hagas push, merge,
despliegue ni promoción del release sin una autorización posterior para publicar.

Prosa revisada: O14, la idea SaaS queda fuera y el tema actual se adopta para este refactor;
O13, una dirección visual aprobada no equivale a un sitio global implementado o validado.
