---
name: supabase-patterns
description: Supabase access conventions for any project on Supabase (Postgres + Auth + RLS) — the three-client model, the server-action auth/authz guard, RLS-first data access, typed queries, and error handling. Self-gating.
when_to_use: "STACK-GATED. Use when reading/writing data, auth, or storage AND the project uses Supabase — detect by checking package.json for @supabase/supabase-js (or @supabase/ssr). If Supabase is NOT in package.json, this skill does NOT apply — ignore it. Framework-agnostic: applies with or without RefineDev."
---

# Supabase patterns

> **Applicability check first.** Read `package.json`. If there is no `@supabase/supabase-js`
> (or `@supabase/ssr`), STOP — this skill does not apply. Otherwise follow it.

## 1. Three clients, by execution context — never mix them up

| Client | Import | Use in | Auth |
|---|---|---|---|
| Browser | `@/lib/supabase/client` (`createClient`) | client components | anon key, user session via cookies |
| Server | `@/lib/supabase/server` (`createClient`, async) | server components, route handlers, **server actions** | anon key, user session from cookies |
| Admin | `@/lib/supabase/admin` (`createAdminClient`) | privileged server-only ops | **service-role key — bypasses RLS** |

- The **server** client is `async` (it awaits cookies). Always `const supabase = await createClient()`.
- The **admin** client bypasses RLS — use it only for deliberate privileged operations (user
  provisioning, cross-tenant jobs), never as a convenience to dodge a policy. Never import it into
  client code; the service-role key must never reach the browser bundle.

## 2. RLS is the security boundary — not the app code

- Every table has **Row Level Security enabled** with explicit policies. The app assumes RLS is on.
- Do **not** rely on client-side filtering for authorization — a missing/`USING (true)` policy is a
  vulnerability even if the UI hides the row.
- App-level role checks (below) are defense-in-depth **on top of** RLS, not a replacement.

## 3. Server-action auth/authz guard — one shared guard per file

Every mutating server action authenticates and authorizes before touching data:

```typescript
"use server";
import { createClient } from "@/lib/supabase/server";

async function requireRole(/* allowed roles */) {
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();   // getUser(), NOT getSession() server-side
  if (!user) throw new Error("No autorizado");
  // role check via the profiles table; throw on insufficient role
  return { supabase, userId: user.id };
}

export async function createThingAction(input: CreateThingInput): Promise<{ id: string }> {
  const { supabase } = await requireRole();
  const { data, error } = await supabase.from("things").insert(input).select("id").single();
  if (error) throw error;          // surface Postgres/RLS errors, never swallow
  return { id: data.id };
}
```

- Use `supabase.auth.getUser()` on the server (it revalidates the token), not `getSession()`.
- Validate input with your schema layer (Zod/etc.) **before** the insert — don't trust the client.

## 4. Typed queries

- Generate DB types: `supabase gen types typescript` → `src/lib/supabase/database.types.ts`, and
  type the clients with `createClient<Database>()`. Don't hand-write row types that drift from schema.
- Select only the columns you need (`.select("id, name")`), and use `.single()` / `.maybeSingle()`
  deliberately — `.single()` throws on 0 or >1 rows.

## 5. Errors & edge cases

- Always destructure `{ data, error }` and handle `error` — never assume success.
- Map Postgres error codes to user-facing messages at the boundary (e.g. `23505` unique violation),
  through `t()` if the project is localized. Don't leak raw DB errors to the UI.
- Storage: signed URLs for private buckets; never expose the service-role key to generate them client-side.

## 6. Secrets

- `NEXT_PUBLIC_SUPABASE_URL` + `NEXT_PUBLIC_SUPABASE_ANON_KEY` are public (anon, RLS-guarded).
- `SUPABASE_SERVICE_ROLE_KEY` is server-only — never `NEXT_PUBLIC_`, never committed, never in client code.

## 7. Migrations — local-first discipline

- **Local-first.** All DDL lands in `supabase/migrations/`; apply + validate locally. Never push DDL straight to prod.
- **Validate the whole chain before a PR:** `supabase db reset` replays every migration + seed from scratch. A green reset is the gate to open the PR.
- **Group a coupled chain into ONE PR/issue.** Don't fragment a sequenced migration set into a PR-per-file. Split only for genuinely independent migrations or a step needing its own review gate (data backfill, RLS behavior change). A single PR also has no siblings to silently revert.
- **Enum `ADD VALUE` is forward-only** and can't run in the same transaction that uses the new label — isolate it as its own earlier migration.
- **Type regen is deliberate, not automatic.** `supabase gen types` may target a *remote* project (check the script) — running it blindly can hit prod or emit types from a stale schema. Regenerate after the chain applies, type-check, then commit the generated file (last / its own PR).
- **Human-gate DDL merges** — review the SQL; don't auto-merge agent-authored migrations.

> If this project also uses RefineDev, the `feature-build-refine` skill covers feature/form/page
> architecture; this skill covers the Supabase data boundary. They compose.
