---
name: feature-build-refine
description: Feature/form/page build strategy for Next.js (App Router) + React + Supabase + RefineDev + shadcn projects. Self-gating — applies ONLY when RefineDev is in the stack.
when_to_use: "STACK-GATED. Use when building features, forms, components, or pages AND the project uses RefineDev — detect by checking package.json for @refinedev/* deps (e.g. @refinedev/core, @refinedev/react-hook-form, @refinedev/react-table). If RefineDev is NOT in package.json, this skill does NOT apply — ignore it. When it applies, follow it exactly; its conventions are non-negotiable for that stack."
---

# Feature / Form / Page Build Strategy (Next.js + Supabase + RefineDev)

> **Applicability check first.** Read `package.json`. If there is no `@refinedev/*` dependency,
> STOP — this skill does not apply to this project. Otherwise follow it exactly. Replace
> `<model>` / `<feature>` with your domain entity. Supabase-specific data patterns are also
> covered by the `supabase-patterns` skill; they compose.

You are building features for a **Next.js 15 (App Router) + React 19 + TypeScript** app with this stack:

- **Backend:** Supabase (PostgreSQL + Auth + RLS)
- **Admin/CRUD framework:** RefineDev with custom data providers wrapping Supabase
- **UI:** shadcn-style component library in `src/components/ui/` (built with `cva` variants + a `cn()` clsx/tailwind-merge helper)
- **Styling:** TailwindCSS v4 with **semantic design tokens** (never hardcoded colors)
- **Forms:** React Hook Form (`@refinedev/react-hook-form`) + Zod validation
- **Tables:** TanStack Table via `@refinedev/react-table`
- **i18n:** i18next — every user-facing string goes through `t()`
- **Icons:** lucide-react, always with an explicit `className` for sizing

Follow the conventions below exactly. They are non-negotiable.

---

## 1. Feature Folder Architecture

Every domain entity is a **self-contained feature module** at `src/features/<model>/`. The folder is **flat** — the only allowed subdirectory is `components/`.

```
src/features/<model>/
├── types.ts          # Domain interfaces & type aliases ONLY (no constants, no fns, no React)
├── constants.ts      # Label maps, option arrays, badge-variant maps, pure helper fns
├── actions.ts        # "use server" — server actions calling Supabase (no types, no React)
├── components/
│   └── <model>-form.tsx   # ONE unified Create/Edit form component
└── index.ts          # Public barrel — re-exports types, constants, components
```

**File responsibility table — enforce strictly:**

| File | Contains | Never contains |
|---|---|---|
| `types.ts` | interfaces, type aliases | constants, functions, React |
| `constants.ts` | label maps, option lists, helpers, badge variants | types, server actions, React |
| `actions.ts` | `"use server"` functions | types, constants, React |
| `components/<model>-form.tsx` | React form component | business logic, DB calls |
| `index.ts` | re-exports | **never re-exports `actions.ts`** |

**Barrel rule:** `index.ts` exports the form component + its `FormData` type + `export * from "./types"` + `export * from "./constants"`. **Server actions are imported directly from `./actions`** — never through the barrel (keeps `"use server"` boundaries clean).

```typescript
// src/features/<model>/index.ts
export { ModelForm } from "./components/<model>-form";
export type { ModelFormData } from "./components/<model>-form";
export * from "./types";
export * from "./constants";
// DO NOT re-export from ./actions — server actions are imported directly
```

**Import discipline:**

- **Inside** the feature boundary, use **relative** imports (`"./types"`, `"../constants"`) — never `@/features/<model>/…`.
- **Outside** consumers import from the barrel: `import { ModelForm, FOO_LABELS } from "@/features/<model>"`.
- **No `src/lib/<model>/`** — feature-specific helpers live in the feature's `constants.ts`. `src/lib/` is only for truly generic, feature-agnostic utilities (`date.ts`, `utils.ts`, `supabase/`, `validations.ts`).
- **No shims** — when moving code, rewrite all import paths with `sed` and delete the old files. Never leave a re-export stub behind.

---

## 2. The Unified Form Component (the core pattern)

There is **ONE component per feature** that handles both Create and Edit. A single `<model>Id?: string` prop drives everything: `isEdit = !!<model>Id`.

### Internal structure (in this order)

```
<model>-form.tsx
├── makeModelSchema(isEdit)      → Zod schema factory; superRefine for mode-aware cross-field rules
├── ModelFormData (exported)     → z.infer<ReturnType<typeof makeModelSchema>>
├── DEFAULT_VALUES               → const covering EVERY field (shared baseline, both modes)
├── Payload (local, unexported)  → type for the edit onFinish cast
└── ModelForm (exported)         → ONE component, ONE return, isEdit drives all branching
```

### Schema: compose from shared primitives, never inline

Keep a `src/lib/validations.ts` of named Zod atoms (`zFullName`, `zEmail`, `zPhone`, `zPhoneOptional`, `zOptionalString`, `zCodigoPostal`, `zUrlOptional`, `zColorHex`, region/enum lists, etc.). **Never write `z.string().min(3).max(100)` when a named primitive exists.**

Mode-aware validation uses a **schema factory + `superRefine`**, not two separate schemas:

```typescript
function makeModelSchema(isEdit: boolean) {
  return z.object({
    // ── Shared ──
    full_name: zFullName,
    email: zEmail,
    // ── Create-only ──
    password: z.string().optional(),
    confirm_password: z.string().optional(),
    // ── Edit-only ──
    status: publicStatusSchema.optional(),
    change_password: z.boolean().default(false),
  }).superRefine((data, ctx) => {
    if (!isEdit) {
      // create-mode cross-field validation (e.g. password match)
    } else {
      // edit-mode cross-field validation
    }
  });
}

export type ModelFormData = z.infer<ReturnType<typeof makeModelSchema>>;
```

`DEFAULT_VALUES` is a single const covering every field (used for both modes and as the spread base for edit values).

### Populate edit data via `values` — NEVER `useEffect + reset()`

This is critical. The fetched record arrives asynchronously; feed it through RHF's `values` prop, which re-initializes the form when its reference changes. `values: undefined` while loading keeps the form at `defaultValues`. `useEffect + reset()` is a banned anti-pattern (stale closures, fires after render).

```typescript
const isEdit = !!modelId;
const schema = useMemo(() => makeModelSchema(isEdit), [isEdit]); // stable; isEdit never changes

// Fetch existing record only in edit mode
const { query, result: record } = useOne<ModelProfile, HttpError>({
  resource: "<table>",
  id: modelId ?? "",
  queryOptions: { enabled: isEdit },
});

// Reactive edit values — undefined until the record arrives
const editValues: ModelFormData | undefined =
  isEdit && record
    ? { ...DEFAULT_VALUES, full_name: record.full_name ?? "", /* …map fields… */ }
    : undefined;

const {
  refineCore: { onFinish, formLoading },
  ...form
} = useForm<BaseRecord, HttpError, ModelFormData>({
  // Bridge Zod's input/output type split WITHOUT `as any`:
  resolver: zodResolver(schema) as unknown as Resolver<ModelFormData>,
  defaultValues: DEFAULT_VALUES,
  values: editValues, // ← drives re-initialization; no useEffect
  refineCoreProps: isEdit
    ? { resource: "<table>", action: "edit", id: modelId, redirect: false, onMutationSuccess: () => { /* router.push + refresh */ } }
    : { action: "create" },
});
```

**Submit handling:** edit flow calls refine's `onFinish` (through the data provider); create flow calls the **server action directly**. When the payload type differs from the form type, cast as `(onFinish as unknown as (v: Payload) => Promise<void>)(payload)`.

### Loading / error guards, then ONE return

```tsx
if (isEdit && query?.isLoading) return <SkeletonCard />;
if (isEdit && (query?.isError || !record)) return <ErrorCard />;

return (
  <Form {...form}>
    <form onSubmit={form.handleSubmit(handleSubmit)} className="space-y-8">
      <FormSection title={t("<feature>.sections.general")}>
        <FormGrid cols={2}>
          <TextField name="full_name" label={t("<feature>.fields.fullName")} icon={UserIcon} control={form.control} />
          <TextField name="email" label={t("<feature>.fields.email")} icon={MailIcon} control={form.control} />
        </FormGrid>
      </FormSection>

      <FormSection title={t("<feature>.sections.details")} separator>
        <FormGrid cols={3}>{/* … */}</FormGrid>
      </FormSection>

      <FormSubmitActions isLoading={isLoading} isEdit={isEdit} onCancel={() => router.back()} />
    </form>
  </Form>
);
```

---

## 3. Form Layout Primitives — always use, never ad-hoc

From `src/components/ui/form-grid.tsx`. **Never** write raw `<div className="grid grid-cols-X gap-Y">` for field rows.

- **`<FormGrid cols={1|2|3|4}>`** — responsive grid, collapses to 1 column on mobile.
- **`<FormSection title description separator>`** — labeled block; `separator` draws a divider above.
- **`<FormActions>`** — right-aligned submit/cancel row.
- **`<FormPanel title description action>`** — bordered row with descriptive text + an action button on the right (for non-field actions inside a form, e.g. "Send recovery email").

## 4. Form Field Primitives — `src/components/forms/`

These are **pure controlled components** (no internal state, no `useForm` inside them). Each wraps the `FormField → FormItem → FormLabel → FormControl → input → FormMessage` chain. Build them once, reuse everywhere:

| Pattern | Component |
|---|---|
| Label + Input (optional icon prefix) | `TextField` (pass `icon={IconComponent}` — **never** a manual wrapper div) |
| Label + Select dropdown | `SelectField` (accepts `Record`, `string[]`, or `{value,label}[]`; uses a `__none__` sentinel because Radix Select rejects empty-string values) |
| Label + Textarea (+ optional char-count) | `TextareaField` |
| Label + row of toggle buttons | `ToggleField` / `ToggleButtonGroup` (single or multiple) |
| Label + searchable multi-select with pills | `MultiSelectField` (wraps `MultiSelectCombobox` — Popover + Command) |
| Label + bordered checkbox + description | `CheckboxField` |
| Label + URL input + image preview | `ImageUrlField` |
| Cancel + Submit button row | `FormSubmitActions` (shows `Loader2` spinner, disables while loading, uses shared `buttons.*` i18n keys) |
| Anything appearing only once | inline `FormField` |

**Extraction rule:** only create a new reusable primitive when the exact raw pattern appears **3+ times** OR a matching primitive already exists. Don't add props for hypothetical future use — add only what the current form needs.

**Array/controlled fields:** always use `render={({ field }) => …}` and pass `field.value` / `field.onChange`. Never reach for `form.getValues` / `form.setValue` on a controlled field.

Example `TextField` (the canonical primitive shape — generic over `FieldValues`, forwards native input props):

```tsx
interface TextFieldProps<T extends FieldValues>
  extends Omit<React.InputHTMLAttributes<HTMLInputElement>, "name"> {
  control: Control<T>;
  name: FieldPath<T>;
  label: string;
  icon?: ComponentType<{ className?: string }>;
  description?: React.ReactNode;
}
// Renders: FormField → FormItem → FormLabel → FormControl → (icon ? relative-wrapped Input.pl-10 : Input) → FormMessage
```

---

## 5. List Pages (DataTable)

Built on TanStack Table via `@refinedev/react-table` + a `DataTable` wrapper in `src/components/refine-ui/data-table/`.

```tsx
const columns = useMemo<ColumnDef<Model>[]>(() => [ /* … */ ], [router]);

const table = useTable<Model>({
  columns,
  refineCoreProps: {
    resource: "<table>",
    filters: { permanent: [{ field: "role", operator: "in", value: [...] }] },
    syncWithLocation: true,
  },
});

const { tableQuery } = table.refineCore;          // NOT tableQueryResult
const data = tableQuery.data?.data ?? [];
```

Column rules:

- **Wrap columns in `useMemo`.** Every column has an `id` and a `size` (px width).
- Use `id` / `accessorKey` / `header` / `cell` (TanStack), **not** `dataIndex` / `render` / `width` (legacy Ant).
- Headers compose `<DataTableSorter>`, `<DataTableFilterDropdownText>`, `<DataTableFilterCombobox>` (multi-select), `<DataTableFilterDropdownNumeric>`.
- Action columns set `enableSorting: false` + `enableColumnFilter: false`.
- Cells use `DataTableTooltip` (hover info), `DataTableBadgeList` (overflowing tag lists), `truncate` for long text.
- Parent container: `min-w-0`; table container `overflow-x-auto`; `minWidth` = sum of column sizes.

Page shell uses `<ListView>` / `<ListViewHeader>` + optional `<ListViewStatistics>` for summary cards.

Recommended column sizes: ID 60–80px · Status badge 100–120px · short text 150–200px · name/title 200–300px · email 200–250px · date 100–120px · actions 60–100px.

---

## 6. Route Pages — thin wiring only

Pages are thin: they pick a View shell and render the feature form/list. No business logic.

```tsx
// <route>/create/page.tsx
"use client";
import { ModelForm } from "@/features/<model>";
import { CreateView } from "@/components/refine-ui/views/create-view";

export default function CreateModelPage() {
  return <CreateView title="Nuevo Model"><ModelForm /></CreateView>;
}

// <route>/[id]/edit/page.tsx
"use client";
import { use } from "react";
import { ModelForm } from "@/features/<model>";
import { EditView } from "@/components/refine-ui/views/edit-view";

export default function ModelEditPage({ params }: { params: Promise<{ id: string }> }) {
  const { id } = use(params);                 // React 19: params is a Promise, unwrap with use()
  return <EditView title="Editar Model"><ModelForm modelId={id} /></EditView>;
}
```

View shells: `CreateView` / `EditView` / `ListView` / `ShowView` (+ their `*Header` variants). Use the canonical path `<route>/[id]/edit/page.tsx` (not `edit/[id]`).

---

## 7. Server Actions

```typescript
// src/features/<model>/actions.ts
"use server";
import { createClient } from "@/lib/supabase/server";
import type { CreateModelInput } from "./types";

async function requireRole() {            // shared auth guard at top of file
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  if (!user) throw new Error("No autorizado");
  // …role check via profiles table…
  return { supabase, userId: user.id };
}

export async function createModelAction(input: CreateModelInput): Promise<{ id: string }> {
  const { supabase } = await requireRole();
  const { data, error } = await supabase.from("<table>").insert(input).select("id").single();
  if (error) throw error;
  return { id: data.id };
}
```

Three Supabase clients, by context (see the `supabase-patterns` skill for detail):

- `@/lib/supabase/client` — browser / client components
- `@/lib/supabase/server` — server components, route handlers, server actions
- `@/lib/supabase/admin` — service-role operations (`createAdminClient`)

---

## 8. Styling & Tokens

- **Semantic tokens only:** `bg-background`, `bg-card`, `bg-muted`, `bg-accent`, `border-border`, `text-foreground`, `text-muted-foreground`, `bg-primary`, `bg-destructive`, etc. These make light/dark themes work. Never hardcode `text-white`, `bg-gray-800`, hex values, or inline `style={{}}`.
- Brand color used sparingly (`text-brand-*`).
- Layout with Tailwind grid/flex utilities — never Ant-style `Row`/`Col`.
- Icons: lucide `*Icon` names, always sized (`<UserIcon className="h-4 w-4" />`).
- Use `cn()` for conditional classes, not template-string concatenation.
- Date formatting: a shared `src/lib/date.ts` (`formatDateShort`, `formatDateMedium`, `formatDateTime`, `formatMonthYear`) — never inline `toLocaleDateString` in feature code.

### UI craft constraints

- `motion/react` for JS animation, `tw-animate-css` for CSS animation.
- Animate **only** `transform` and `opacity`, never layout properties. Interaction feedback ≤ 200ms.
- Radix primitives for keyboard/focus behavior; `AlertDialog` for destructive actions.
- `text-balance` for headings, `tabular-nums` for data. `h-dvh` not `h-screen`. No gradients unless explicitly requested.

---

## 9. i18n

Every user-facing string goes through `t()` from `useTranslation()`. Keys live in `public/locales/<lang>/common.json` under a namespace matching the feature name. No hardcoded display strings in JSX. Use shared keys for generic buttons (`buttons.cancel`, `buttons.save`, `buttons.create`).

---

## 10. Non-Negotiable Rules (checklist)

1. Feature folder is **flat** — only `components/` subdir allowed.
2. File names are **dashed-case** (`model-form.tsx`, `constants.ts`).
3. **No `src/lib/<model>/`** — feature code goes in `constants.ts`.
4. **No shims** — rewrite imports with `sed`, delete old files.
5. **No `as any`** — use `as unknown as SpecificType` with a comment.
6. **Relative imports inside the feature**, barrel imports outside.
7. **`actions.ts` never re-exported** from `index.ts`.
8. **Shared date formatting** via `@/lib/date`.
9. **Form layout** always via `FormGrid`/`FormSection`/`FormActions` — no ad-hoc grids.
10. **Controlled fields** use `field.value`/`field.onChange`, never `getValues`/`setValue`.
11. **`values` not `useEffect + reset()`** for edit population.
12. **No constants in `.tsx`** — they belong in `constants.ts`; check shared validations first.
13. **Compose Zod from shared primitives**, don't duplicate inline chains.
14. **All strings through `t()`**.
15. **`TextField` icon via `icon` prop**, never manual wrapper divs.
