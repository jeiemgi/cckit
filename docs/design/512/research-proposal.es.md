# cckit: propuesta de documentación y explicación del producto

Fecha de la sesión: 18 de noviembre de 2026, Ciudad de México.

Estado: propuesta para revisión. Recoge las decisiones de José durante la entrevista y distingue las recomendaciones que todavía no se han aprobado. No implementa cambios en el sitio.

## 1. Dirección definida en la entrevista

| Tema | Decisión expresada por José |
| --- | --- |
| Público principal | Personas que desarrollan con un agente de código. El recorrido inicial solo puede dar por hecho que saben conversar con él. |
| Intención central | Dar estructura al trabajo con IA, convertir las prácticas del proyecto en un proceso reutilizable y conectar las herramientas existentes. Continuidad, supervisión y coordinación son beneficios adicionales. |
| Primera demostración | Explicar cómo se conectan las herramientas. |
| Proyecto de ejemplo | Una pequeña app de reservas. |
| Participación del lector | Aplicar el proceso a su propio proyecto. La app de reservas ilustra los pasos; construirla no es un requisito. |
| Idiomas | Experiencia completa en inglés y español, incluidas guías y referencia. |
| Glosario | Breve y contextual. Introducir palabras cuando la historia las necesita. |
| Recursos visuales | Diagramas, ilustraciones y animaciones que expliquen operaciones; demos y capturas coherentes con la misma historia. |

José cuestionó mantener Marketing como sitio y estilo separados y propuso integrarlo en los docs. La recomendación de esta propuesta es hacerlo. La taxonomía y los nombres concretos siguientes siguen abiertos a revisión.

## 2. Qué se revisó

Se compararon la portada y páginas seleccionadas de `http://localhost:4321/` y `http://localhost:4322/`, además de la versión recuperada de `https://cckit.dev/`. La versión pública recuperada muestra la portada anterior, encabezada por `a project OS for coding agents`.

En el repositorio se revisaron las entradas de Software y Marketing, instalación e inicialización, el primer trabajo de Marketing, revisión y aprobación, planificación, componentes de conversación y desplegables, diagramas, navegación, configuración de Astro y búsqueda. También se consultó la implementación de las tareas locales.

Puntos de referencia de Git:

- Checkout principal consultado: `develop`, commit `b220390`.
- Rama de las muestras nuevas: `task/512-docs-guides-less-text-more-visual`, commit `889e72f`.
- Directorio de esa rama: `.claude/worktrees/task+512-docs-guides-less-text-more-visual/`.

La muestra servida en el puerto 4321 coincide con la versión abreviada de esas páginas. Se verificó la correspondencia de contenido; no se inspeccionó el proceso que lanzó el servidor.

Esto es una revisión editorial y técnica de recorridos seleccionados. No incluye pruebas con lectores ni una comprobación exhaustiva de cada página o enlace.

## 3. Diagnóstico de la reescritura actual

### Hubo recorte y ocultamiento, no una sustitución por explicaciones visuales

La comparación `git diff --numstat develop...task/512-docs-guides-less-text-more-visual` devuelve:

| Archivo bajo `docs-site/src/content/docs/` | Líneas añadidas | Líneas eliminadas |
| --- | ---: | ---: |
| `getting-started/initialize.mdx` | 32 | 68 |
| `marketing/your-first-piece.mdx` | 31 | 55 |
| `es/marketing/your-first-piece.mdx` | 39 | 65 |
| Total | 102 | 188 |

Son conteos de cambios, no una medida de comprensión. La rama no modifica componentes de diagramas ni añade ilustraciones o animaciones.

En inicialización se trasladan a desplegables las diferencias entre terminal y agente, y el comportamiento de `--yes`. Parte de la salida de ejemplo se sustituye por `…`. También se elimina la línea visible que exigía haber instalado cckit y tener un `cckit doctor` sin problemas.

En el primer trabajo de Marketing, tiempos, fallos y el caso de una persona que trabaja sola pasan a desplegables. Se acortan las introducciones y las explicaciones de cada paso. El requisito inicial sigue disponible mediante `TutorialMeta`.

La recomendación es clasificar cada fragmento antes de moverlo:

| Contenido | Tratamiento propuesto |
| --- | --- |
| Requisito para poder continuar | Visible antes del paso. |
| Acción y resultado esperado | Visibles junto al ejemplo. |
| Fallo que detiene ese paso | Mensaje reconocible y salida hacia la solución. |
| Explicación técnica adicional | Bloque opcional con nombre descriptivo. |
| Salida completa, flags y casos menos frecuentes | Referencia enlazada, conservando los hechos. |
| Repetición sin información adicional | Eliminar indicando la repetición concreta. |

La divulgación progresiva reserva lo secundario para cuando se necesita. No consiste en esconder las condiciones necesarias para completar una tarea. Referencia: [NN/g, Progressive Disclosure](https://www.nngroup.com/articles/progressive-disclosure/).

### La división Software / Marketing mezcla criterios

Actualmente la ruta determina qué navegación, acento visual y convenciones de escritura recibe el lector. `src/lib/tracks.ts` y `src/routeData.ts` implementan esa separación. Marketing también tiene restricciones de vocabulario y una traducción propia al español.

Pero las páginas de Marketing incluyen sitios, landing pages y pequeñas apps, tareas que también pertenecen al desarrollo de software. Además, un lector de Software puede no conocer Git. La división no permite deducir de forma consistente ni qué quiere hacer una persona ni qué conocimientos tiene.

Recomendación: una documentación común organizada por necesidades y tareas. Mantener campañas, voz de marca y contenido como casos de uso. Los perfiles del CLI pueden conservar sus nombres.

La investigación de NN/g identifica dificultades cuando una persona pertenece a varias categorías de audiencia o debe identificarse antes de encontrar su tarea. Esto respalda revisar la división; no sustituye una prueba con usuarios de cckit. Fuente: [Audience-Based Navigation](https://www.nngroup.com/articles/audience-based-navigation/).

### Hay componentes reutilizables, pero falta una narración visual común

`Chat.astro` ya ofrece mensaje, comandos, respuesta y explicación. `Outcomes.astro` conserva detalles en bloques expandibles. Son bases que conviene revisar y reutilizar.

Los diagramas usan React Flow con zoom y desplazamiento. `FlowBase.tsx` anima las conexiones que tienen etiqueta mediante `animated: !!label`. No contiene una secuencia didáctica de estados con avanzar, retroceder o reproducir.

En la vista de escritorio inspeccionada, los nodos del ciclo principal se reducían de 150 a unos 91 píxeles de ancho. La transformación reduce también el texto de 15 px a unos 9 px aparentes. El lector tiene que ampliar la vista para leerlo.

Antes de animar esos gráficos hay que corregir qué dicen:

- `GitHubCycle.tsx` muestra `Merge / into main`, mientras que el ejemplo de inicialización usa `develop`. Usar el término definido para la rama de integración o el valor del ejemplo.
- `WorktreeIsolation.tsx` dice `merges, no clashes`. Separar carpetas evita que los agentes editen la misma copia de trabajo. No elimina los posibles conflictos al integrar cambios.
- Un visual de esfuerzos debe conservar la excepción del producto: un esfuerzo completo abre un PR, no uno por cada subtarea.

### Algunas frases presentan una intención como si fuera una garantía

Ejemplos encontrados:

| Frase o comportamiento | Precisión necesaria |
| --- | --- |
| Cada cambio comienza con un issue | cckit también tiene tareas locales. Indicar qué modo usa el recorrido. |
| Cada comando habla con GitHub | Hay comandos locales, incluido `version`. |
| Antes de mostrar el resultado se comprueba el sitio | `task run` usa `--check`, después `tasks.check`, y puede ejecutarse sin gate si ninguno existe. Mostrar la configuración que sostiene el ejemplo. |
| Enlace para mirar y aprobar la página | La guía de aprobación actual abre una revisión de archivos en GitHub. Una vista navegable de la app es un resultado distinto. |
| La revisión siempre requiere otra persona | Distinguir la política elegida, las posibilidades de GitHub y el caso de trabajo individual. |

La nueva explicación debe distinguir lo que hace el comando, lo que indican las reglas al agente y lo que el proyecto configuró como obligatorio.

## 4. Arquitectura propuesta del sitio

| Entrada | Pregunta que resuelve | Contenido |
| --- | --- | --- |
| Portada | ¿Qué añade cckit a lo que ya uso? | Definición concreta, mapa de herramientas, muestra del proceso y acceso al recorrido. |
| Empieza en tu proyecto | ¿Cómo lo uso aquí? | Recorrido conversacional, requisitos y comprobaciones. |
| Guías | ¿Cómo hago esta tarea? | Revisar, retomar, coordinar, diseñar, crear contenido y preparar campañas. |
| Cómo funciona | ¿Por qué trabaja así? | Aislamiento, reglas, responsabilidades, dependencias y límites. |
| Referencia | ¿Qué hace este comando o ajuste? | CLI, configuración, perfiles, adaptadores e integraciones. |

El glosario estará disponible desde el recorrido y la búsqueda, sin ser un requisito previo. El selector de idioma estará presente en toda la experiencia.

Los nombres de la tabla son propuestas de navegación, no rutas existentes ni decisiones de implementación.

Diátaxis distingue aprendizaje práctico, resolución de tareas, explicación y consulta. Conviene usar esa distinción al editar cada página; no es necesario poner esos cuatro nombres como menú público. Fuente: [Diátaxis](https://diataxis.fr/).

## 5. Historia del proyecto de reservas

La app permite elegir un servicio, consultar horarios y reservar una cita. Es un ejemplo propuesto, no una demo ya construida. El dominio concreto y el nombre todavía no se han elegido.

El lector ve una situación en esa app y realiza el paso equivalente en su propio proyecto. No tiene que copiar su stack ni implementar sus funciones.

| Capítulo inicial | En el ejemplo | En el proyecto del lector | Evidencia visible |
| --- | --- | --- | --- |
| Conoce las conexiones | Agente, cckit, proyecto y GitHub | Identificar qué herramientas y configuración ya existen | Mapa explicado y diagnóstico. |
| Prepara el proyecto | Configurar el proyecto de reservas | Añadir lo que falte, conservando su configuración existente | Resultado del setup y comprobación. |
| Define un cambio | Mostrar la duración de los servicios | Elegir una mejora pequeña y describir cómo comprobarla | Trabajo registrado con alcance claro. |
| Haz y revisa el cambio | La duración aparece en la app | Construir la mejora y revisar su resultado | Antes/después, comprobaciones y revisión. |
| Continúa otro día | Recuperar el siguiente trabajo pendiente | Consultar el estado y retomar | Registro de lo terminado y lo pendiente. |

Capítulos posteriores: corregir un error, dividir una mejora mayor, trabajar en paralelo y preparar una publicación. Cada uno introduce capacidades cuando la historia las necesita.

Cada capítulo conserva este orden: qué queremos cambiar, qué pedirle al agente, qué sucede y qué comprobar. Incluye una salida para quien necesita ayuda y un enlace al siguiente paso.

## 6. Set de componentes propuesto

Los nombres siguientes describen responsabilidades; no son APIs aprobadas.

| Componente | Uso | Reglas |
| --- | --- | --- |
| Mapa de herramientas | Explicar las relaciones iniciales | Seleccionar una herramienta revela su función y conexiones. Separar herramientas necesarias y opcionales. |
| Escena por etapas | Mostrar una operación y sus consecuencias | Avanzar, volver, reproducir y pausar. El estado actual se entiende sin movimiento. |
| Conversación accionable | Mostrar qué pedir, dónde hacerlo y qué esperar | Etiquetar ejemplos. El mensaje copiable se adapta al proyecto del lector. Los comandos quedan disponibles. |
| Vista de evidencia | Mostrar una captura anotada, un antes/después o un clip | Misma escena y versión que la explicación. Los clips tienen controles y alternativa legible. |
| Acceso a la demo | Explorar el resultado del ejemplo | Abrir la versión del capítulo. Señalar los datos y acciones simulados. |
| Término contextual | Explicar vocabulario sin perder el lugar | Activación por toque y teclado, sin depender del hover. Una definición canónica por concepto. |
| Detalle técnico | Consultar condiciones, comandos y resultados completos | Títulos que expliquen qué contiene. Los requisitos para avanzar permanecen visibles. |

No todas las páginas necesitan todos los componentes. Una referencia puede funcionar con texto y tablas. Un mapa complejo puede justificar React Flow; una explicación breve puede resolverse con SVG y estados de interfaz.

### Guion de la primera animación

1. Presentar el proyecto y el agente con el que conversa el lector.
2. Seleccionar el agente muestra qué puede leer y modificar.
3. Incorporar cckit muestra las operaciones del proceso que el agente puede ejecutar.
4. Conectar GitHub muestra dónde quedan registrados el trabajo y los cambios.
5. Abrir las reglas y habilidades muestra cómo el proyecto indica su forma de trabajar.

Cada relación se explica con una acción concreta. Evitar una nube de logos con flechas sin significado. Las herramientas opcionales se exploran después.

### Coherencia de los materiales

Cada escena debe identificar el capítulo, la versión del ejemplo, el idioma, el resultado visible y los recursos asociados. Un mismo registro puede enlazar la demo, las capturas y el guion de animación.

El contrato editorial es verificable: el nombre de una tarea, la pantalla modificada y su estado coinciden en texto, diagramas, capturas y demo. Un cambio aprobado en GitHub no se representa automáticamente como desplegado en producción.

## 7. Glosario que acompaña la historia

No abrir el recorrido con un catálogo. Presentar primero la situación y definir la palabra cuando ayuda a entenderla.

| Momento | Término posible | Definición de trabajo |
| --- | --- | --- |
| Conectar GitHub | Repositorio | El proyecto guardado en GitHub, con sus archivos e historial de cambios. |
| Registrar una mejora | Issue | Un registro de trabajo en GitHub con lo que se quiere hacer y cómo comprobarlo. |
| Trabajar por separado | Worktree | Una carpeta con su propia copia del proyecto para trabajar en un cambio. |
| Presentar el resultado | Pull request | Una propuesta de cambios en GitHub que se puede revisar antes de integrarla. |
| Aceptar el cambio | Merge | Integrar los cambios propuestos en la rama de destino del proyecto. |

Estas son definiciones iniciales para revisión, no un límite definitivo del glosario. Si el recorrido necesita otra palabra, se introduce allí. `Effort`, `wave`, hooks, receipts y los roles especializados esperan hasta sus capítulos.

Conservar los términos reales facilita reconocerlos en GitHub y en el agente. Prohibirlos por audiencia, como hace hoy `marketing-words.mjs`, deberá revisarse si desaparece esa división.

## 8. Voz y tono

La voz propuesta es cercana, concreta y precisa. Explica el trabajo real sin dar por sabida su terminología.

- Hablarle a la persona que está usando su agente y su proyecto.
- Explicar acciones y resultados antes de enumerar mecanismos.
- Conservar un nombre por concepto. No alternar asistente, agente y ayudante para el mismo actor.
- Evitar analogías que añadan otra cosa que aprender, como OS del proyecto, agencia o llaves.
- Evitar `simplemente`, `fácil`, `solo tienes que` y tiempos de éxito sin contexto.
- Separar el resultado observado, el ejemplo ilustrativo y el comportamiento configurado.
- Mantener visibles las condiciones y los límites que hacen verdadera una explicación.

Google recomienda una voz conversacional y respetuosa, términos consistentes y lenguaje comprensible para lectores con distintos niveles de inglés. También desaconseja presentar los procedimientos como fáciles. Fuente: [Google developer style, Voice and tone](https://developers.google.com/style/tone).

### Muestra de portada para discutir

Español:

> Dale un proceso a tu trabajo con agentes.
>
> cckit conecta tu agente, las reglas de tu proyecto y GitHub. Reúne comandos y habilidades para registrar el trabajo, preparar cambios y revisar el resultado desde la conversación con tu agente.
>
> Ver cómo se conecta · Usarlo en mi proyecto

English:

> Give your coding agent a process to follow.
>
> cckit connects your coding agent, your project's rules, and GitHub. It brings together commands and skills to track work, prepare changes, and review the result through conversations with your agent.
>
> See how it fits together · Use it in my project

Son borradores de voz y posicionamiento. No son copy final aprobado.

### Muestra de instrucción adaptable

Español:

> Revisa este proyecto y dime qué hace, qué herramientas usa y si ya tiene cckit. Consulta la documentación de cckit y explícame qué falta para usarlo aquí. Primero muéstrame lo que encontraste.

English:

> Review this project and tell me what it does, which tools it uses, and whether cckit is already set up. Check the cckit documentation and explain what is missing to use it here. First, show me what you found.

La app de reservas tendría su propia conversación de ejemplo junto a este mensaje genérico. No se copia el nombre de la demo ni un número de issue al proyecto del lector.

## 9. Qué permite el proyecto Astro actual

El manifiesto declara Astro `^7.3.1`, Starlight `^0.42.0`, React `^19.2.7` y React Flow `^12.11.1`. MDX y los componentes existentes permiten desarrollar esta propuesta sin cambiar de framework.

Propuesta técnica:

- Conservar el texto, las definiciones y el resumen de cada escena en HTML.
- Añadir interactividad como componentes aislados, sin convertir cada página en una aplicación completa.
- Para componentes compatibles con renderizado inicial, usar hidratación al entrar en la vista cuando corresponda.
- Los diagramas actuales usan `client:only="react"`. Si se mantiene ese modo, incluir una explicación estática equivalente. Cambiar la directiva por sí sola no garantiza que React Flow pueda renderizarse durante el build.
- Compartir estados y etiquetas entre la escena y su explicación. Las traducciones no deben depender de texto incrustado en una imagen.

Astro documenta que `client:visible` carga e hidrata cuando el componente entra en la vista, y que `client:only` omite el renderizado HTML inicial del componente. Fuente: [Astro, Client directives](https://docs.astro.build/en/reference/directives-reference/#client-directives).

Las animaciones deben tener pausa, respetar la preferencia de movimiento reducido y conservar una representación estática legible. Usar estas condiciones como criterios de diseño; esta revisión no certifica conformidad de accesibilidad. Fuentes: [W3C, Animation from Interactions](https://www.w3.org/WAI/WCAG22/Understanding/animation-from-interactions.html) y [Pause, Stop, Hide](https://www.w3.org/WAI/WCAG22/Understanding/pause-stop-hide.html).

## 10. Algolia: búsqueda y respuestas sobre los docs

### Estado observado

`astro.config.mjs` activa el plugin de Algolia cuando encuentra las credenciales de búsqueda y el índice. Si no, conserva Pagefind. En el puerto 4321 se observó la interfaz de Pagefind.

`SearchStart.astro` muestra preguntas sugeridas, pero abre la búsqueda existente y coloca allí el texto. No genera respuestas. `Chat.astro` contiene conversaciones escritas por el autor de la página; no es un chat de consulta.

El proyecto declara `@astrojs/starlight-docsearch` `^0.8.0`; el lockfile resuelve DocSearch `3.9.0`. La configuración no incluye `askAi`, `agentId` ni un backend conversacional.

### Capacidad investigada

Algolia ofrece respuestas conversacionales a partir del contenido indexado. La documentación actual de DocSearch v5 usa Agent Studio y conserva el nombre de opción `askAi`, con un `agentId`. Tiene integración JavaScript y React. Fuente: [DocSearch, Get started with Agent Studio](https://docsearch.algolia.com/docs/agent-studio/getting-started/).

No basta añadir una opción al plugin instalado basado en DocSearch v3. Hay que validar un camino de actualización compatible o reemplazar el componente de búsqueda por una integración compatible con v5. Starlight permite sustituir su proveedor de búsqueda. Fuente: [Starlight, Site Search](https://starlight.astro.build/guides/site-search/).

### Experiencia propuesta

Conservar la búsqueda por palabras y añadir `Pregunta sobre cckit`. La respuesta debería enlazar la sección que la sostiene y ofrecer el siguiente paso relacionado con el capítulo.

Preguntas para validar:

- ¿Qué necesito antes de usar cckit en mi proyecto?
- ¿Qué cambiará al inicializarlo?
- ¿Dónde pego este mensaje?
- ¿Por qué el agente no puede empezar el trabajo?
- ¿El enlace de revisión abre la app o GitHub?
- ¿Un esfuerzo abre un PR por cada subtarea?
- ¿Aprobar un cambio lo publica en internet?

El índice debe diferenciar versiones e idiomas y cubrir el contenido de las escenas mediante texto recuperable. Revisar qué extrae el crawler de desplegables y de componentes que solo aparecen con JavaScript. El chat de docs no conoce por sí mismo el estado privado del proyecto del lector.

DocSearch permite configurar índices y filtros para las consultas del agente. Fuente: [Configure dynamic indices](https://docsearch.algolia.com/docs/agent-studio/dynamic-indices/).

El programa DocSearch es gratuito bajo sus condiciones. Esto no demuestra que cualquier uso de modelos o configuración de Agent Studio tenga coste cero. El acceso y las condiciones de la cuenta de cckit no se comprobaron. Fuentes: [DocSearch program](https://docsearch.algolia.com/docs/docsearch-program/) y [Algolia, Is Ask AI free?](https://support.algolia.com/hc/en-us/articles/38478303035665-Is-Ask-AI-free).

## 11. Cómo organizar la reescritura

1. Inventariar las páginas en ambas lenguas y asignarles una función. Para cada fragmento: conservar, reescribir, mover, combinar o retirar, con motivo y destino. Las líneas recortadas no prueban que algo sea prescindible.
2. Diseñar una sección completa del recorrido con su escena, explicación, términos y ejemplo. Mantener visibles requisitos y resultado esperado. Probarla en inglés y español antes de extender el patrón.
3. Construir los componentes que esa sección necesita. Validar legibilidad y navegación en móvil y escritorio.
4. Preparar la app demo y los estados que documenten los capítulos. Capturar pruebas visuales de esos estados. No presentar las pruebas anteriores de la panadería como mediciones de la nueva app.
5. Reorganizar el contenido común, integrar los casos de uso de Marketing y conservar la equivalencia de cada enlace mediante la estrategia de redirecciones del sitio.
6. Reescribir las demás páginas usando el patrón que corresponda a su función. Traducir texto, componentes y recursos en el mismo alcance.
7. Integrar las respuestas conversacionales, revisar la extracción del contenido y evaluar preguntas en ambas lenguas sobre el release objetivo.
8. Hacer una prueba observada con lectores que sepan conversar con un agente pero no conozcan cckit. Registrar dónde dudan y qué necesitan que se les explique.

Esta secuencia es una propuesta de ejecución. No crea un effort, issues, compromisos de tiempo ni un nuevo alcance de release aprobado.

## 12. Criterios para revisar el resultado

- Una persona puede explicar qué conecta cckit y dónde trabaja después de recorrer la introducción.
- Puede encontrar un primer paso aplicable a su proyecto sin construir obligatoriamente la app demo.
- Cada instrucción dice dónde se realiza, qué necesita y cómo reconocer su resultado.
- Las animaciones son legibles a tamaño normal y el contenido sigue disponible sin movimiento.
- Las condiciones esenciales no dependen de abrir un desplegable.
- El texto y los visuales distinguen revisión de archivos, vista navegable, integración y publicación.
- Los nombres y estados coinciden entre capítulo, demo, capturas y diagramas.
- El recorrido funciona completo en inglés y español. Los comandos mantienen sus nombres reales.
- La referencia conserva comandos, flags, errores y límites que estaban documentados.
- Las respuestas de Algolia enlazan fuentes del idioma y la versión pertinentes; si el contenido no alcanza para responder, lo indican.

Son criterios propuestos para validar el trabajo, no resultados de pruebas ya realizadas.

## 13. Decisiones que siguen abiertas

- Aprobar los nombres de navegación y el copy de la portada.
- Elegir el contexto y el nombre de la app de reservas.
- Definir qué interacciones de la demo son funcionales y cuáles están simuladas.
- Revisar diferencias de configuración para Claude Code y Codex, conservando el recorrido común.
- Confirmar el camino compatible y las condiciones de cuenta para Algolia.
- Acordar qué parte entra en el release y cómo se divide el trabajo.

### Revisión editorial aplicada

Se aplicó el criterio de cortar por un problema identificable y conservar evidencia, condiciones y números:

| Hallazgo | Tratamiento en la propuesta |
| --- | --- |
| O10, jerga usada sin explicación: `project OS` | Proponer una definición que nombre agente, proyecto, reglas y GitHub. |
| O13, garantía sin sustento: `merges, no clashes` | Describir el aislamiento de carpetas y conservar la posibilidad de conflictos de integración. |
| O13, comportamiento condicionado presentado como universal | Identificar el gate, la política o el modo que hace verdadero el ejemplo. |
| O14, alternativas presentadas como decisiones | Separar las respuestas de José, las recomendaciones y los puntos abiertos. |

No se eliminaron páginas ni se aplicaron recortes al repositorio durante esta investigación.

## 14. Anexo visual: wireframes, layout y tipografía

Añadido el 19 de noviembre de 2026. Estas exploraciones desarrollan la propuesta; no son un diseño aprobado ni una implementación del sitio.

[Abrir las seis láminas visuales](https://chatgpt.com/library?file_id=libfile_a945df38950481919bc6c46fbeb3c1fd&account_id=personal).

[Abrir el archivo HTML con la simulación de cuatro pasos](https://chatgpt.com/library?file_id=libfile_15aa5d0b5b408191953921a599994e11&account_id=personal). El archivo puede descargarse y abrirse en un navegador. La secuencia del tutorial permite avanzar, volver y repetir. La navegación representada dentro de los wireframes es ilustrativa.

| Lámina | Qué muestra |
| --- | --- |
| 01. Portada | Una definición del producto junto al mapa de herramientas; acciones para entender las conexiones y empezar en el proyecto propio. |
| 02. Tutorial | Capítulos compactos, lectura y demostración juntas, requisito visible, mensaje copiable, definición contextual y comprobación. |
| 03. Móvil | Dos composiciones en una columna. La escena cambia de posición y presenta una relación por vista. |
| 04. Tipografía | Tres direcciones comparadas con el mismo mensaje en español e inglés. |
| 05. Storyboard | Pedido registrado, copia de trabajo separada, comprobaciones y resultado para revisar. |
| 06. Ilustración y layout | Exploración de apoyo visual y reglas iniciales de composición, espaciado y forma. |

### Layout recomendado

En portada, repartir el espacio entre la explicación y el mapa. Mantener una acción principal para explorar las conexiones y otra para usar cckit en el proyecto del lector. El ejemplo de reservas aparece después de esa explicación.

En tutoriales, reservar la navegación izquierda para los capítulos del recorrido. La zona de contenido combina el paso escrito y su demostración. El índice de encabezados derecho deja de competir con la escena. Cuando el ancho no permita conservar texto legible, la escena pasa debajo del paso.

Los wireframes móviles muestran una composición específica para ese ancho. No proponen reducir el mapa completo de escritorio ni exigir desplazamiento horizontal para leerlo.

Valores iniciales propuestos para el sitio: contenedor de 1200–1280 px, columna de lectura de 60–72 caracteres, cuerpo de 17–18 px e interlineado de 1.6–1.7. Son parámetros a validar con el contenido real, no resultados de una prueba de usabilidad.

### Tres direcciones tipográficas

| Dirección | Títulos | Texto | Comandos | Valoración |
| --- | --- | --- | --- | --- |
| A. Clara y técnica | Geist | Geist | Geist Mono | Recomendada. Ya está en el proyecto y permite concentrar el cambio en jerarquía, tamaño y espaciado. |
| B. Humana y abierta | Source Sans 3 | Source Sans 3 | Geist Mono | Alternativa con formas menos geométricas. Comparar con páginas de lectura larga. |
| C. Guía editorial | Source Serif 4 | Geist | Geist Mono | Alternativa para dar carácter a la portada y los textos de autor. Mantener la lectura operativa en sans serif. |

Las cuatro familias se cargaron y se comprobaron en el navegador al preparar las láminas. La valoración estética es una recomendación, no una afirmación de que una familia haya demostrado mayor comprensión.

Fuentes oficiales: [Geist](https://vercel.com/font), [Source Sans](https://github.com/adobe-fonts/source-sans) y [Source Serif](https://github.com/adobe-fonts/source-serif).

### Cómo usar las imágenes de apoyo

La ilustración generada reúne ventanas de conversación, una app de reservas y una revisión. Sirve para explorar el lenguaje visual. No representa un registro real ni una descripción exacta de las operaciones.

Los wireframes y el storyboard se construyeron con texto y formas de interfaz para conservar etiquetas legibles y estados definidos. La futura documentación usará capturas de la app demo y resultados de ejecuciones reales cuando necesite probar un comportamiento.

La simulación preparada contiene cuatro estados explicativos. Se comprobó que los controles avanzan y retroceden y que el contenido sigue disponible con movimiento reducido. No ejecuta cckit ni realiza reservas. Las láminas se inspeccionaron visualmente y el PDF contiene seis páginas.


## 15. Referencias de identidad: Kito, compañeros, logo y stickers

[Ver el documento de identidad con cinco láminas](https://chatgpt.com/library?file_id=libfile_d6b346499dd081919362815f94d61908&account_id=personal).

José aprobó la dirección de la familia: Kito es una terminal, el Post-it representa un ticket y la memoria USB representa la memoria del proyecto. La tecla K y las exploraciones anteriores de personajes quedan descartadas como identidad de Kito.

El estilo elegido es Cuaderno de código: contornos de plumón, desfase de impresión, zonas de puntos y una paleta de azul cobalto, tinta oscura, marfil, salvia y ocre. Las ilustraciones táctiles de papel anteriores permanecen como exploraciones previas.

El documento reúne la imagen maestra aprobada, seis poses de cada uno de los tres personajes y una lámina de propuestas de logo y stickers. Las cuatro composiciones de marca son: `cckit`, `cckit.dev`, `cckit` acompañado de Kito y una etiqueta `cckit.dev` con el símbolo de terminal. Las propuestas de logo todavía requieren selección.

Para nuevas escenas se adjunta la imagen maestra y se describen solo los cambios de pose o acción. Las poses nuevas se revisan frente al original antes de incorporarlas al repertorio. La reproducción exacta se obtiene reutilizando el archivo aprobado.
