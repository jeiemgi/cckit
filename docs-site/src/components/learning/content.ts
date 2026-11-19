// Content for the learning components (ToolsMap.astro, StagedScene.astro), in English and Spanish.
// The components render this as plain HTML at build time; no text lives in an image or a canvas.
// Reference project of the examples: a small appointment-booking app. Nothing here is output from
// a run: the state rows are an illustration and the components label them as one.

export type Lang = 'en' | 'es';

/** Language of a page, from its path: /es/... is Spanish, everything else English. */
export function langOf(pathname: string): Lang {
	return /^\/es(\/|$)/.test(pathname) ? 'es' : 'en';
}

// ── Tools map ───────────────────────────────────────────────────────────────────────────────────

export type ToolId = 'you' | 'agent' | 'cckit' | 'project' | 'github';

export interface Tool {
	id: ToolId;
	name: string;
	/** What it is, in a few words, under the name. */
	kind: string;
	/** One or two sentences: what it does in this picture. */
	role: string;
}

export interface Relation {
	from: ToolId;
	to: ToolId;
	/** The action, as a verb phrase read between the two names. */
	action: string;
	/** One sentence with the concrete example. May contain <code>. */
	detail: string;
}

export interface ToolsMapContent {
	label: string;
	toolsHeading: string;
	relationsHeading: string;
	filterHint: string;
	showAll: string;
	/** "{n} of {total} connections involve {name}" — placeholders are replaced by the script. */
	filterStatus: string;
	allStatus: string;
	tools: Tool[];
	relations: Relation[];
}

export const toolsMap: Record<Lang, ToolsMapContent> = {
	en: {
		label: 'How the tools connect',
		toolsHeading: 'The five parts',
		relationsHeading: 'What each one does to the next',
		filterHint: 'Select a part to see only its connections.',
		showAll: 'Show all connections',
		filterStatus: '{n} of {total} connections involve {name}.',
		allStatus: 'All {total} connections.',
		tools: [
			{ id: 'you', name: 'You', kind: 'The person', role: 'You say what you want in the chat and you review the result.' },
			{
				id: 'agent',
				name: 'Your agent',
				kind: 'Claude Code or Codex',
				role: 'It reads the project, edits files and runs commands. It is the only part that writes code.',
			},
			{
				id: 'cckit',
				name: 'cckit',
				kind: 'A command-line tool',
				role: 'It gives the agent commands for the steps of a change: record it, start it, send it to review.',
			},
			{
				id: 'project',
				name: 'Your project',
				kind: 'Your files',
				role: 'Your code, plus the instruction files and rules cckit adds so the agent knows how this project works.',
			},
			{
				id: 'github',
				name: 'GitHub',
				kind: 'Where the project is stored',
				role: 'It keeps the list of work and shows each proposed change for review.',
			},
		],
		relations: [
			{ from: 'you', to: 'agent', action: 'ask in the chat', detail: 'You describe the change in your own words. You do not type commands.' },
			{
				from: 'agent',
				to: 'project',
				action: 'reads the instructions, edits the files',
				detail: 'At the start of a session the agent reads the instruction file (<code>CLAUDE.md</code> or <code>AGENTS.md</code>) and the rules next to it.',
			},
			{
				from: 'agent',
				to: 'cckit',
				action: 'runs commands',
				detail: 'For example <code>cckit start &lt;issue&gt;</code> to begin a change and <code>cckit pr &lt;issue&gt; "&lt;summary&gt;"</code> to send it to review.',
			},
			{
				from: 'cckit',
				to: 'project',
				action: 'writes the setup, makes a separate copy per change',
				detail: '<code>cckit init</code> writes the config, the instruction file and the rules once. Each change then gets its own folder, so unfinished work stays out of your main files.',
			},
			{
				from: 'cckit',
				to: 'github',
				action: 'records work, opens the review',
				detail: 'It uses the GitHub command-line tool (<code>gh</code>) that you signed in to. cckit stores no token of its own.',
			},
			{ from: 'you', to: 'github', action: 'review the change', detail: 'You read the proposed change on GitHub and approve it or ask for changes.' },
		],
	},
	es: {
		label: 'Cómo se conectan las herramientas',
		toolsHeading: 'Las cinco partes',
		relationsHeading: 'Qué le hace cada una a la siguiente',
		filterHint: 'Selecciona una parte para ver solo sus conexiones.',
		showAll: 'Mostrar todas las conexiones',
		filterStatus: '{n} de {total} conexiones incluyen a {name}.',
		allStatus: 'Las {total} conexiones.',
		tools: [
			{ id: 'you', name: 'Tú', kind: 'La persona', role: 'Dices en el chat lo que quieres y revisas el resultado.' },
			{
				id: 'agent',
				name: 'Tu agente',
				kind: 'Claude Code o Codex',
				role: 'Lee el proyecto, edita archivos y ejecuta comandos. Es la única parte que escribe código.',
			},
			{
				id: 'cckit',
				name: 'cckit',
				kind: 'Una herramienta de línea de comandos',
				role: 'Le da al agente comandos para los pasos de un cambio: registrarlo, empezarlo, enviarlo a revisión.',
			},
			{
				id: 'project',
				name: 'Tu proyecto',
				kind: 'Tus archivos',
				role: 'Tu código, más los archivos de instrucciones y las reglas que cckit añade para que el agente sepa cómo se trabaja en este proyecto.',
			},
			{
				id: 'github',
				name: 'GitHub',
				kind: 'Donde se guarda el proyecto',
				role: 'Guarda la lista de trabajo y muestra cada cambio propuesto para revisarlo.',
			},
		],
		relations: [
			{ from: 'you', to: 'agent', action: 'pides en el chat', detail: 'Describes el cambio con tus palabras. No escribes comandos.' },
			{
				from: 'agent',
				to: 'project',
				action: 'lee las instrucciones, edita los archivos',
				detail: 'Al empezar una sesión el agente lee el archivo de instrucciones (<code>CLAUDE.md</code> o <code>AGENTS.md</code>) y las reglas que lo acompañan.',
			},
			{
				from: 'agent',
				to: 'cckit',
				action: 'ejecuta comandos',
				detail: 'Por ejemplo <code>cckit start &lt;issue&gt;</code> para empezar un cambio y <code>cckit pr &lt;issue&gt; "&lt;resumen&gt;"</code> para enviarlo a revisión.',
			},
			{
				from: 'cckit',
				to: 'project',
				action: 'escribe la configuración, crea una copia separada por cambio',
				detail: '<code>cckit init</code> escribe una vez la configuración, el archivo de instrucciones y las reglas. Después cada cambio recibe su propia carpeta, y el trabajo sin terminar queda fuera de tus archivos principales.',
			},
			{
				from: 'cckit',
				to: 'github',
				action: 'registra el trabajo, abre la revisión',
				detail: 'Usa la herramienta de línea de comandos de GitHub (<code>gh</code>) con la sesión que tú iniciaste. cckit no guarda ningún token propio.',
			},
			{ from: 'you', to: 'github', action: 'revisas el cambio', detail: 'Lees el cambio propuesto en GitHub y lo apruebas o pides cambios.' },
		],
	},
};

// ── Staged scene ────────────────────────────────────────────────────────────────────────────────

export type RowState = 'none' | 'new' | 'kept' | 'changed';

export interface Step {
	title: string;
	/** What happens, as HTML (may contain <code> and <strong>). */
	body: string;
	/** A word defined at the step that first needs it. */
	term?: { word: string; definition: string };
	/** A limit or condition that keeps the step true. */
	note?: string;
	/** State of each tracked thing after this step, in the order of `SceneContent.tracks`. */
	state: { value: string; state: RowState }[];
}

export interface SceneContent {
	label: string;
	/** The change the scene follows, shown above the steps. */
	example: string;
	/** Names of the things whose state the scene tracks. */
	tracks: string[];
	stateHeading: string;
	illustration: string;
	steps: Step[];
}

export interface SceneUi {
	previous: string;
	next: string;
	replay: string;
	play: string;
	pause: string;
	showAll: string;
	showOne: string;
	controls: string;
	/** "Step {n} of {total}: {title}" */
	status: string;
	stepWord: string;
	reducedMotion: string;
	termLabel: string;
	noteLabel: string;
	stateWords: Record<RowState, string>;
}

export const sceneUi: Record<Lang, SceneUi> = {
	en: {
		previous: 'Previous step',
		next: 'Next step',
		replay: 'Back to step 1',
		play: 'Play the steps',
		pause: 'Pause',
		showAll: 'Show all steps',
		showOne: 'Show one step at a time',
		controls: 'Step controls',
		status: 'Step {n} of {total}: {title}',
		stepWord: 'Step',
		reducedMotion: 'Automatic play is off because your system asks for reduced motion. Use Previous and Next.',
		termLabel: 'New word',
		noteLabel: 'Keep in mind',
		stateWords: { none: 'not yet', new: 'new in this step', kept: 'unchanged', changed: 'changed in this step' },
	},
	es: {
		previous: 'Paso anterior',
		next: 'Paso siguiente',
		replay: 'Volver al paso 1',
		play: 'Reproducir los pasos',
		pause: 'Pausar',
		showAll: 'Mostrar todos los pasos',
		showOne: 'Mostrar un paso a la vez',
		controls: 'Controles de los pasos',
		status: 'Paso {n} de {total}: {title}',
		stepWord: 'Paso',
		reducedMotion: 'La reproducción automática está desactivada porque tu sistema pide menos movimiento. Usa Anterior y Siguiente.',
		termLabel: 'Palabra nueva',
		noteLabel: 'Ten en cuenta',
		stateWords: { none: 'todavía no', new: 'nuevo en este paso', kept: 'sin cambios', changed: 'cambió en este paso' },
	},
};

/** One small change in the appointment-booking app, from the request to a reviewed pull request. */
export const smallChange: Record<Lang, SceneContent> = {
	en: {
		label: 'One small change, from the request to a reviewed pull request',
		example: 'The change: each service in the booking app shows how long it lasts.',
		tracks: ['Record of the work', 'Separate copy', 'The change', 'Review'],
		stateHeading: 'Where things stand after this step',
		illustration: 'Illustration of the booking-app example. It is not output from a run.',
		steps: [
			{
				title: 'You ask for the change',
				body: 'In the chat you say what you want and how you will know it is done: <strong>each service shows its duration before the visitor picks a time</strong>.',
				note: 'Nothing has changed in the app yet.',
				state: [
					{ value: 'Not recorded', state: 'none' },
					{ value: 'None', state: 'none' },
					{ value: 'Not started', state: 'none' },
					{ value: 'None', state: 'none' },
				],
			},
			{
				title: 'The agent records the work',
				body: 'Your agent writes the request down before it touches code. In a project that keeps its work list on GitHub it runs <code>cckit new</code>, which creates an issue.',
				term: {
					word: 'Issue',
					definition: 'A record of one piece of work on GitHub: what should change and how to check it.',
				},
				note: 'A project can keep its list in its own files instead, with no GitHub issue: there the agent runs <code>cckit task new</code>. The steps below are the same in both modes with other command names.',
				state: [
					{ value: 'Issue open', state: 'new' },
					{ value: 'None', state: 'none' },
					{ value: 'Not started', state: 'none' },
					{ value: 'None', state: 'none' },
				],
			},
			{
				title: 'The change gets its own copy of the project',
				body: 'Your agent runs <code>cckit start &lt;issue&gt;</code>. cckit creates a branch and a worktree for this one change and the agent works there.',
				term: {
					word: 'Branch and worktree',
					definition: 'A branch is a named line of changes, separate from the version everyone shares. A worktree is a folder holding the project on that branch, so your main files stay as they were.',
				},
				note: 'A worktree keeps files apart while the work is in progress. Two changes to the same lines can still conflict when they are combined later.',
				state: [
					{ value: 'Issue open', state: 'kept' },
					{ value: 'Branch and worktree created', state: 'new' },
					{ value: 'Not started', state: 'none' },
					{ value: 'None', state: 'none' },
				],
			},
			{
				title: 'The agent makes the change and runs the checks',
				body: 'In that folder the agent edits the files and saves its progress as commits. Then it runs the checks your project has configured, such as a build or a test command.',
				term: {
					word: 'Commit',
					definition: 'A saved point in the history of the project, with a short message saying what changed.',
				},
				note: 'Which checks run depends on your project. cckit runs the ones you configured and adds none of its own; a project with no check has nothing to pass here.',
				state: [
					{ value: 'Issue open', state: 'kept' },
					{ value: 'Branch and worktree in use', state: 'kept' },
					{ value: 'Made in the separate copy', state: 'new' },
					{ value: 'None', state: 'none' },
				],
			},
			{
				title: 'The agent opens a pull request',
				body: 'Your agent runs <code>cckit pr &lt;issue&gt; "&lt;summary&gt;"</code>. cckit sends the branch to GitHub and opens a pull request linked to the issue. The agent gives you the link.',
				term: {
					word: 'Pull request (PR)',
					definition: 'A page on GitHub that proposes the changes of one branch, shows every changed line and collects the review.',
				},
				note: 'A pull request shows files. It does not run your app: seeing the page in a browser needs a preview, which is a separate thing your project may or may not have.',
				state: [
					{ value: 'Issue open, linked to the PR', state: 'changed' },
					{ value: 'Branch sent to GitHub', state: 'changed' },
					{ value: 'Proposed, not yet in the shared version', state: 'changed' },
					{ value: 'Pull request open', state: 'new' },
				],
			},
			{
				title: 'You review it',
				body: 'You open the link and read the change, or a colleague does. If something is off, say so in the chat: the agent updates the same pull request. The scene ends here, with a reviewed pull request.',
				note: 'The change is still a proposal. The shared version of the project is unchanged until someone merges.',
				state: [
					{ value: 'Issue open, linked to the PR', state: 'kept' },
					{ value: 'Branch sent to GitHub', state: 'kept' },
					{ value: 'Proposed, not yet in the shared version', state: 'kept' },
					{ value: 'Pull request reviewed', state: 'changed' },
				],
			},
		],
	},
	es: {
		label: 'Un cambio pequeño, desde el pedido hasta un pull request revisado',
		example: 'El cambio: cada servicio de la app de citas muestra cuánto dura.',
		tracks: ['Registro del trabajo', 'Copia separada', 'El cambio', 'Revisión'],
		stateHeading: 'Cómo queda todo después de este paso',
		illustration: 'Ilustración del ejemplo de la app de citas. No es la salida de una ejecución.',
		steps: [
			{
				title: 'Pides el cambio',
				body: 'En el chat dices qué quieres y cómo sabrás que está hecho: <strong>cada servicio muestra su duración antes de que el visitante elija un horario</strong>.',
				note: 'Todavía no ha cambiado nada en la app.',
				state: [
					{ value: 'Sin registrar', state: 'none' },
					{ value: 'Ninguna', state: 'none' },
					{ value: 'Sin empezar', state: 'none' },
					{ value: 'Ninguna', state: 'none' },
				],
			},
			{
				title: 'El agente registra el trabajo',
				body: 'Tu agente anota el pedido antes de tocar el código. En un proyecto que lleva su lista de trabajo en GitHub ejecuta <code>cckit new</code>, que crea un issue.',
				term: {
					word: 'Issue',
					definition: 'Un registro de un trabajo en GitHub: qué debe cambiar y cómo comprobarlo.',
				},
				note: 'Un proyecto puede llevar su lista en sus propios archivos, sin issue de GitHub: ahí el agente ejecuta <code>cckit task new</code>. Los pasos siguientes son los mismos en ambos modos, con otros nombres de comando.',
				state: [
					{ value: 'Issue abierto', state: 'new' },
					{ value: 'Ninguna', state: 'none' },
					{ value: 'Sin empezar', state: 'none' },
					{ value: 'Ninguna', state: 'none' },
				],
			},
			{
				title: 'El cambio recibe su propia copia del proyecto',
				body: 'Tu agente ejecuta <code>cckit start &lt;issue&gt;</code>. cckit crea una rama y un worktree para este cambio y el agente trabaja ahí.',
				term: {
					word: 'Rama y worktree',
					definition: 'Una rama (branch) es una línea de cambios con nombre, separada de la versión que todos comparten. Un worktree es una carpeta con el proyecto en esa rama, de modo que tus archivos principales quedan como estaban.',
				},
				note: 'Un worktree mantiene los archivos separados mientras el trabajo está en curso. Dos cambios en las mismas líneas todavía pueden chocar cuando se combinen después.',
				state: [
					{ value: 'Issue abierto', state: 'kept' },
					{ value: 'Rama y worktree creados', state: 'new' },
					{ value: 'Sin empezar', state: 'none' },
					{ value: 'Ninguna', state: 'none' },
				],
			},
			{
				title: 'El agente hace el cambio y ejecuta las comprobaciones',
				body: 'En esa carpeta el agente edita los archivos y guarda su avance en commits. Después ejecuta las comprobaciones que tu proyecto tiene configuradas, como un build o un comando de pruebas.',
				term: {
					word: 'Commit',
					definition: 'Un punto guardado en el historial del proyecto, con un mensaje corto que dice qué cambió.',
				},
				note: 'Qué comprobaciones se ejecutan depende de tu proyecto. cckit ejecuta las que configuraste y no añade ninguna propia; un proyecto sin comprobaciones no tiene nada que pasar aquí.',
				state: [
					{ value: 'Issue abierto', state: 'kept' },
					{ value: 'Rama y worktree en uso', state: 'kept' },
					{ value: 'Hecho en la copia separada', state: 'new' },
					{ value: 'Ninguna', state: 'none' },
				],
			},
			{
				title: 'El agente abre un pull request',
				body: 'Tu agente ejecuta <code>cckit pr &lt;issue&gt; "&lt;resumen&gt;"</code>. cckit envía la rama a GitHub y abre un pull request enlazado al issue. El agente te da el enlace.',
				term: {
					word: 'Pull request (PR)',
					definition: 'Una página de GitHub que propone los cambios de una rama, muestra cada línea cambiada y reúne la revisión.',
				},
				note: 'Un pull request muestra archivos. No ejecuta tu app: ver la página en un navegador requiere una vista previa, que es algo aparte que tu proyecto puede tener o no.',
				state: [
					{ value: 'Issue abierto, enlazado al PR', state: 'changed' },
					{ value: 'Rama enviada a GitHub', state: 'changed' },
					{ value: 'Propuesto, aún fuera de la versión compartida', state: 'changed' },
					{ value: 'Pull request abierto', state: 'new' },
				],
			},
			{
				title: 'Lo revisas',
				body: 'Abres el enlace y lees el cambio, o lo hace un colega. Si algo no está bien, dilo en el chat: el agente actualiza el mismo pull request. La escena termina aquí, con un pull request revisado.',
				note: 'El cambio sigue siendo una propuesta. La versión compartida del proyecto no cambia hasta que alguien haga el merge.',
				state: [
					{ value: 'Issue abierto, enlazado al PR', state: 'kept' },
					{ value: 'Rama enviada a GitHub', state: 'kept' },
					{ value: 'Propuesto, aún fuera de la versión compartida', state: 'kept' },
					{ value: 'Pull request revisado', state: 'changed' },
				],
			},
		],
	},
};
