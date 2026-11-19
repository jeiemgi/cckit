# Revisión requerida: la entrada sigue siendo difícil de entender

Feedback de José tras ver la primera entrega: “sigue verbosa complicada de entender” y
“what is this :S !? nobody will read this”. Las capturas muestran la página completa que motiva
esta revisión. Este documento prevalece sobre la autorización anterior de avanzar a la entrega 02.

## Decisión del director

La primera entrega no queda aprobada como entrada al producto. Conservamos el código que sirva,
pero pausamos la expansión a portada, navegación y más páginas hasta corregir la muestra.
Mi brief anterior pidió demasiadas cosas simultáneas y produjo una explicación que exige leer
la estructura de la herramienta antes de entender su utilidad. No se corrige acortando frases
ni añadiendo flechas a las mismas tarjetas.

## Qué está fallando en las capturas

- El visitante encuentra título abstracto, párrafo, una mascota grande, prerrequisitos y cinco
  fichas antes de ver una situación reconocible. No ve qué resultado obtendrá.
- El supuesto mapa es una lista de seis relaciones con explicaciones. El lector tiene que
  reconstruir mentalmente el conjunto. Los filtros añaden trabajo para descubrirlo.
- La escena es otro panel de lectura: párrafo, definición, advertencia y tabla de cuatro estados.
  Avanzar cambia el texto; no permite ver cómo cambia el proyecto.
- Cinco controles aparecen juntos para manejar esa lectura. La interfaz requiere aprender
  a usar la explicación antes de comprender el producto.
- Las dos barras laterales, el cambio Software/Marketing y las cajas anidadas compiten con
  la historia. La mascota ocupa el espacio donde debería ocurrir la demostración.
- Comandos, modos de tareas, autenticación, Git y matices de publicación llegan antes de que
  el usuario entienda por qué querría probar cckit.

## Nueva unidad: una escena visual que explique una mejora

Usa el ejemplo ya decidido: una app de reservas de servicios. Evita “app de citas” en español,
porque puede interpretarse como una app para encontrar pareja.

La primera pantalla debe mostrar una petición reconocible y su resultado. Dirección de copy
para explorar, no promesa de automatización universal:

“De una idea a un cambio que puedes revisar.”

Texto de apoyo: “cckit le da a tu agente instrucciones y un proceso para trabajar en tu proyecto.”

La escena muestra una petición corta: “Muestra cuánto dura cada servicio antes de reservar”.
El usuario ve la misma mejora avanzar por tres momentos:

1. **Pides un cambio.** Un mensaje breve junto a la interfaz del servicio sin duración.
2. **Tu agente lo prepara con cckit.** Aparece un registro de la petición y un cambio separado
   del proyecto compartido. Una señal visual conecta instrucciones, trabajo y archivos.
3. **Revisas el resultado.** La interfaz muestra la duración añadida, con un acceso reconocible
   a revisar el cambio. Queda claro que todavía no se ha publicado.

Cada momento tiene una frase de apoyo y un objeto que cambia. El texto nombra la acción;
la ilustración demuestra el resultado. No añadas una definición, advertencia y tabla a cada paso.
Los tres momentos son un resumen de la historia, no una especificación de los verbos de cckit.

Usa una escena de interfaz ilustrativa coherente con el mismo proyecto. Identifícala una vez
como ejemplo ilustrativo. No inventes una captura real, resultado de prueba ni salida de CLI.
Kito puede señalar el trabajo o acompañar la transición; no sustituye a la demostración.

## Interacción y composición

- Una escena principal con el contexto visible. Puede usar pestañas numeradas o Anterior/Siguiente.
  Replay/play son secundarios; no presentes una botonera de cinco acciones al entrar.
- El cambio visual debe entenderse también sin animación. Respetar movimiento reducido,
  teclado, foco y contenido estático sigue siendo requisito.
- En móvil los mismos objetos se reorganizan sin reducir el texto para encajar.
- Usa un layout de introducción con espacio para la escena; no encierres la entrada en la
  columna de un artículo entre dos barras laterales completas. La referencia conserva su layout.
- Mostrar una llamada principal a continuar y un enlace secundario a cómo funciona.
  No exigir Git instalado ni cuentas para mirar la explicación.

## Dónde va el detalle

El detalle técnico se conserva en las guías de instalación, el recorrido completo y la referencia.
La siguiente guía práctica muestra sus prerrequisitos antes de pedir ejecutar nada.
La entrada puede enlazar a esas páginas sin desarrollar todas sus condiciones.
No escondas prerrequisitos esenciales detrás de un expander en una guía ejecutable.
El mapa completo puede quedar como explicación secundaria accesible, fuera de la primera escena.

## Entrega y verificación

Rehaz solo la muestra EN/ES y los componentes necesarios. No extiendas aún este patrón al resto
del sitio. Registra qué se conserva, qué se mueve y dónde queda disponible cada detalle.
Corrige también las afirmaciones absolutas señaladas en `review-01.md`.

Presenta capturas de la primera pantalla y la escena de resultado en escritorio/móvil y ambos
temas. Además del build y los checks pertinentes, responde con evidencia visible:

- ¿Se identifica la mejora concreta sin leer párrafos ni pulsar filtros?
- ¿Se distingue qué aporta cckit del trabajo del agente?
- ¿Se ve el cambio entre antes y después?
- ¿Hay un siguiente paso claro, sin un glosario o comandos como barrera de entrada?

Son preguntas de revisión del diseño, no una prueba de comprensión con usuarios. No afirmes que
“se entiende en segundos” sin haberlo observado. No push, merge ni despliegue en esta revisión.

Prosa durable revisada: O13, no se confunden requisitos de comprensión con resultados comprobados;
O14, se decide pausar la entrega 02 y rehacer la muestra antes de expandirla.
