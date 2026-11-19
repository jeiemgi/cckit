# Revisión 01: la entrada rehecha como una escena visual

Escrito el 2026-11-19 por Claude Code. Responde a `feedback-01-revision.es.md` y a las
correcciones de `review-01.md`. Rama `task/512-docs-guides-less-text-more-visual`, sobre `84b82eb`.
Sin push, merge ni despliegue. La entrega 02 sigue en pausa.

## Qué hay ahora

La entrada es una página nueva, `/learn/` (`/es/learn/` en español), con el layout `splash` de
Starlight: sin barra lateral ni índice de la página. En 1280×900 la primera pantalla contiene el
título, una frase, la escena completa y las dos llamadas a continuar.

La escena (`ChangeStory.astro`) cuenta una mejora de una app de reservas de servicios en tres
momentos. La app dibujada ocupa el mismo lugar en los tres, a 386 px del borde superior en
1280×900, medido en Chrome.

| Momento | Frase | Objeto que cambia |
| --- | --- | --- |
| 1. Pides un cambio | "Dices lo que quieres en el chat con tu agente." | El mensaje "Muestra cuánto dura cada servicio antes de reservar." junto a la app sin duraciones. |
| 2. Tu agente lo prepara con cckit | "cckit le da a tu agente las instrucciones de tu proyecto, anota el pedido y mantiene el trabajo aparte." | Tres objetos bajo "cckit prepara" (instrucciones, pedido anotado, copia separada junto al proyecto compartido), una flecha y, debajo, "Tu agente hace el trabajo" con Kito. La app sigue sin cambios. |
| 3. Revisas el resultado | "El cambio está listo para que lo veas. Todavía no se ha publicado nada." | Una tarjeta "Cambio propuesto" con antes y después, y las etiquetas "Listo para tu revisión" y "Sin publicar". La app muestra las tres duraciones, cada una marcada "añadido". |

Controles al entrar: tres pestañas numeradas y un botón "Siguiente". No hay reproducción
automática, "replay" ni filtros. La escena se identifica una vez como ejemplo ilustrativo. No
contiene comandos, salida de CLI, capturas reales ni resultados de pruebas.

Debajo: una llamada principal, "Prepararlo en tu proyecto" (lleva a la guía de instalación, que
muestra sus prerrequisitos), un enlace secundario, "Cómo funciona, parte por parte", y el enlace
al otro idioma.

## Qué se conserva, qué se mueve y dónde queda cada detalle

| Detalle de la primera entrega | Dónde queda |
| --- | --- |
| Las cinco partes y las seis conexiones (`ToolsMap.astro`) | `/learn/how-the-tools-connect/`, enlazada como "Cómo funciona, parte por parte". Seleccionar una parte ya no oculta filas: marca las suyas y atenúa las demás. |
| Los seis pasos con comandos, términos y límites (`StagedScene.astro`) | La misma página de detalle. Anterior y Siguiente son los controles; volver al paso 1, reproducir y ver todos los pasos pasan a un grupo secundario con aspecto de enlace. |
| Merge y despliegue como acciones separadas | La misma página de detalle. Añade que algunos alojamientos construyen una vista previa cuando la rama llega a GitHub, antes de cualquier merge. |
| Lista de trabajo en archivos (light tasks) | La misma página de detalle, con enlace a su guía. |
| Prerrequisitos (agente, cckit instalado, cuenta de GitHub, `cckit init`) | Visibles en la página de detalle y en la guía de instalación. La entrada no pide nada para mirarla. |
| Ilustración grande del trío | Retirada de ambas páginas. La copia en `components/learning/assets/` se borró; el original sigue en `references/`. |
| Kito | En el momento 2, a 88 px, junto a "Tu agente hace el trabajo". Es el recorte de la pose que señala (celda superior derecha de `references/kito-poses.png`, 512×512, alfa menor de 40 llevado a 0, bordes recortados). Decorativo, `alt=""`. |

Correcciones de `review-01.md` aplicadas en `content.ts` y en las dos páginas de detalle:

- "Es la única parte que escribe código" pasa a "Puede editar archivos y ejecutar comandos en tu
  proyecto", en ambos idiomas.
- "Una secuencia fija de pasos" pasa a "un ejemplo de flujo de trabajo", y nombra las listas de
  tareas en archivos, los trabajos divididos en partes y los grados de automatización.
- La nota sobre comprobaciones se limita al ejemplo y ya no dice que cckit no añade ninguna.
- "App de citas" pasa a "app de reservas" en todo el texto en español.

No aplicado de `review-01.md`: el punto 1 pedía un visual con las cinco partes y las seis
conexiones dibujadas juntas. El feedback posterior deja el mapa como explicación secundaria, así
que se quedó en filas, con el cambio de ocultar a atenuar.

## Las cuatro preguntas de revisión

Son respuestas de quien lo construyó, con la captura que las sostiene. Nadie ajeno al proyecto ha
mirado la página, así que no dicen si un visitante la entiende ni en cuánto tiempo.

| Pregunta | Qué se ve | Captura |
| --- | --- | --- |
| ¿Se identifica la mejora concreta sin leer párrafos ni pulsar filtros? | La petición es el objeto más grande de la primera pantalla, en una burbuja de chat, junto a la lista de servicios sin duración. No hay filtros. En escritorio no hace falta desplazarse; en 360×740 se ve la petición y la app empieza justo debajo del borde. | `en-dark-1280x900-first-screen`, `es-light-360x740-first-screen` |
| ¿Se distingue qué aporta cckit del trabajo del agente? | En el momento 2 hay dos recuadros con nombre: "cckit prepara" (tres objetos) y "Tu agente hace el trabajo" (una acción). Para verlo hay que pasar al momento 2: no está en la primera pantalla. | `es-dark-1280x900-moment-2` |
| ¿Se ve el cambio entre antes y después? | La app está en el mismo lugar en los tres momentos; en el 3 cada servicio gana una línea con su duración, contorneada y con la palabra "añadido". La tarjeta repite antes y después con un servicio. | `en-dark-1280x900-result`, `es-light-1280x900-result`, las dos `…-360x740-result` |
| ¿Hay un siguiente paso claro, sin glosario ni comandos como barrera? | Un botón principal y un enlace secundario bajo la escena, dentro de la primera pantalla en 1280×900 (el botón termina a 869 px de 900). La entrada no tiene glosario ni comandos. | `en-dark-1280x900-first-screen` |

## Verificación

- `pnpm --dir docs-site build`: sale 0, 217 páginas (215 antes de esta revisión).
- `bash scripts/update-path-test.sh`: `ALL OK (update-path)`.
- `bash scripts/docs-marketing-words-test.sh`: `all ok`.
- `bash scripts/check.sh`: `117 passed, 0 failed`, `PASS cckit check passed`, sobre el estado final
  con los archivos ya preparados para el commit.
- Sin JavaScript: en `dist/` las dos rutas contienen los tres momentos sin atributo `hidden`, tres
  pantallas de la app, las tres duraciones y ningún `<canvas>`. Las pestañas y los dos botones
  "Siguiente" llevan `hidden` y los activa el script.
- Teclado, con pulsaciones reales en Chrome: flecha derecha pasa de la pestaña 1 a la 2, Tab llega
  a "Siguiente", Enter muestra el momento 3 y deja el foco en su pestaña, con contorno de 3 px.
- Movimiento reducido emulado: `animation-name` es `none` en los tres momentos.
- 320 px: sin desplazamiento horizontal ni elementos fuera del borde en los tres momentos; texto
  mínimo de 14 px. En pantallas estrechas las pestañas no seleccionadas muestran solo su número y
  conservan su nombre para lectores de pantalla.
- Contraste, medido en Chrome en ambos temas: el texto más bajo es 4.70 (pestaña seleccionada y
  botón principal en oscuro) y 4.85 (rótulos atenuados en oscuro). El texto sobre los objetos
  dibujados va de 6.16 (blanco sobre cobalto) a 15.58 (carbón sobre marfil).

### Capturas

En `evidence/revision-01/`, tomadas de `http://localhost:4321/`, servido por este worktree, con
los archivos de esta revisión sin confirmar sobre `84b82eb`.

| Archivo | Ruta | Tamaño | Estado |
| --- | --- | --- | --- |
| `en-dark-1280x900-first-screen.jpeg` | `/learn/` | 1280×900 | momento 1, oscuro |
| `en-dark-1280x900-result.jpeg` | `/learn/` | 1280×900 | momento 3, oscuro |
| `es-light-1280x900-first-screen.jpeg` | `/es/learn/` | 1280×900 | momento 1, claro |
| `es-light-1280x900-result.jpeg` | `/es/learn/` | 1280×900 | momento 3, claro |
| `es-dark-1280x900-moment-2.jpeg` | `/es/learn/` | 1280×900 | momento 2, oscuro |
| `en-dark-360x740-first-screen.jpeg` | `/learn/` | 360×740 a 2x | momento 1, oscuro |
| `en-dark-360x740-result.jpeg` | `/learn/` | 360×740 a 2x | momento 3, oscuro |
| `es-light-360x740-first-screen.jpeg` | `/es/learn/` | 360×740 a 2x | momento 1, claro |
| `es-light-360x740-result.jpeg` | `/es/learn/` | 360×740 a 2x | momento 3, claro |

## Límites y pendientes

- **El momento 2 solo se capturó en escritorio y en oscuro.** En móvil y en claro se revisó que no
  desborda (320 px) y su contraste, sin guardar imagen.
- **El cambio Software/Marketing sigue en la cabecera.** El feedback lo nombra como competencia de
  la historia. Vive en `Header.astro`, que es navegación global y queda para la entrega 02.
- **En móvil la app no cabe entera en la primera pantalla.** En 360×740 se ven título, frase,
  pestañas y petición; la app empieza en el borde inferior. El título ocupa tres líneas.
- **El momento 1 deja un hueco** bajo la burbuja en escritorio: la columna izquierda tiene un solo
  objeto y la app fija la altura.
- **Las páginas siguen fuera de la barra lateral y del sitemap en español**, igual que en la
  primera entrega (`delivery-01.md`, *Not done, and risks*).
- **No se probó** con lector de pantalla, ni en Safari o Firefox. La escena usa consultas de
  contenedor de CSS.
- **Los nombres de los servicios** (corte de pelo, color, arreglo de barba) son una elección de
  esta revisión; el paquete solo fija "app de reservas de servicios".
- **Seguimiento.** Las entregas 02 a 06 siguen sin issues nativos. `review-01.md` pide prepararlos
  con cckit; no se hizo aquí porque el feedback limita esta revisión a la muestra.

## Siguiente acción de revisión

Abrir `http://localhost:4321/learn/` y `http://localhost:4321/es/learn/`, recorrer los tres
momentos en escritorio y en un ancho de móvil, en ambos temas, y decidir si esta escena es la
entrada antes de reanudar la entrega 02.

Prosa durable revisada: O13, las cuatro respuestas dicen qué se ve en una captura y que ningún
visitante la ha probado; O14, se decide mover el detalle a la página secundaria y dejar el mapa en
filas, y se nombra lo que queda para la entrega 02.
