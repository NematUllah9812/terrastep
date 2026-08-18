# Terrastep — Credential Handling

Terrastep stores **where people physically walk**. A leaked admin key here isn't
an inconvenience — it's a database of users' movement patterns. This file is the
operating rule set. Read it before Phase 2, when real keys enter the picture.

---

## 1. The sorting question

Before creating or sharing any credential, ask:

> **"If this were posted publicly, what's the worst that happens?"**

That single question sorts every credential correctly:

| Credential | If leaked | Class |
|---|---|---|
| Supabase **publishable** key (`sb_publishable_…`) | Nothing. RLS holds. | Public |
| Mapbox / MapTiler public token | Quota abuse at worst | Public-ish (set URL restrictions) |
| Fine-grained GitHub PAT, 1 repo, Contents | One repo you already shared, briefly | Low blast radius |
| Classic GitHub PAT (`repo` scope) | **Every repo you own**, read + write | High blast radius |
| Vercel personal token | All projects, deployments, env vars | High blast radius |
| Supabase **secret** key (`sb_secret_…`) | **Total data compromise.** Bypasses RLS. Every user's location history. | Critical |

Anything in the bottom two rows never gets pasted into a chat, a commit, a
screenshot or a support ticket.

---

## 2. Supabase keys — the split that matters

Supabase has **two independent credential systems**. Confusing them is the most
common way projects like this get breached.

### 2a. Project API keys (how the app talks to the DB)

| Key | Format | Privilege | Goes where |
|---|---|---|---|
| **Publishable** | `sb_publishable_…` | Low — RLS applies | Flutter app, public code, this repo. **Safe to commit.** |
| **Secret** | `sb_secret_…` | Elevated — **bypasses RLS** | Server-side only. Edge Functions, cron, admin tooling. |

The publishable key is *designed* to be public. It identifies the project, not a
person. **Row Level Security is what protects the data — not the key's secrecy.**
That is exactly why `01_DATA_MODEL.sql` grants `authenticated` zero direct write
access and funnels every mutation through `claim_cells()`.

The secret key is the dangerous one:
- Never in the Flutter app. Anything shipped to a phone is extractable — treat
  the app bundle as public.
- Never in this repo, not even in an example file.
- Set it as an environment variable in the Supabase dashboard (reachable from a
  phone browser), never by pasting it into code someone else wrote.
- Create **one named secret key per service**. If one leaks, delete just that one
  and the rest keep running.

### 2b. Personal Access Tokens (Management API / CLI)

These carry **the same privileges as your whole user account**. Same handling as
a classic GitHub PAT: avoid creating one unless you specifically need to automate
the Management API. For Terrastep you don't — SQL goes in through the dashboard.

### 2c. Use the new key format

Legacy `anon` / `service_role` JWT keys are removed in **late 2026**. Start on the
new format:

> Dashboard → Settings → API Keys → **API Keys** tab (not Legacy) → *Create new API keys*

Nothing in this repo needs changing: `sb_secret_…` still maps to the
`service_role` Postgres role, so the RLS policies and `GRANT` statements in
`01_DATA_MODEL.sql` are unaffected. Benefits over the legacy keys:

- **Instant deletion** — dead within seconds, no JWT-secret rotation cascade.
- **Browser-blocked at the gateway** — a secret key used from a browser gets a
  401. It cannot leak through client-side code.
- **Auto-revoked** if Supabase's GitHub secret scanning spots it in a public repo.

---

## 3. Delegating a push (agent, contractor, CI)

Default: **don't share a credential at all.** Set up `gh auth login` or an SSH key
and push yourself. A secret never transmitted cannot be intercepted, logged, or
stored.

When that isn't possible (e.g. no laptop access), use a **fine-grained** PAT:

**Create the repo first** — fine-grained tokens can only select repositories that
already exist. Make it in the GitHub mobile app, then generate the token.

| Setting | Value |
|---|---|
| Repository access | **Only select repositories** → the one repo |
| Contents | **Read and write** |
| Metadata | Read-only *(forced, can't disable)* |
| Workflows | Read and write — **only if** the commit touches `.github/workflows/` |
| Everything else | **No access** |
| Account permissions | **No access**, all of them |
| Expiration | Shortest available — 1–7 days |

Then **delete it as soon as the push lands.** Never reuse a token across sessions;
the value of a short-lived credential comes precisely from not reusing it.

⚠️ **The Workflows gotcha.** Contents write does *not* cover workflow files. A push
touching `.github/workflows/` fails with:

```
refusing to allow a Personal Access Token to create or update workflow
`.github/workflows/tests.yml` without `workflow` scope
```

Enable Workflows for that commit, then drop back to Contents-only.

⚠️ Contents write still allows **force-push and branch deletion**. Minimal is not
harmless — which is why prompt deletion matters more than tight scoping.

---

## 4. If something leaks

Order matters. Deleting the key is necessary but **not sufficient**.

1. **Delete the credential** (GitHub, Vercel and Supabase all label the button
   *Delete*; "revoke" is the generic industry term for the same action).
2. **Audit what was done with it.** Deletion stops *future* use — it does not undo
   past actions. Check for: unexpected commits, new deploy keys, altered
   workflows, new tokens minted, changed repo settings.
3. **For a Supabase secret key specifically:** treat it as a full database
   compromise. Review database logs — the secret key bypasses RLS and leaves *no
   per-user audit trail*, so you cannot reconstruct who did what after the fact.
4. **Rotate, then redeploy.** On platforms that inject secrets at build time
   (Vercel), rotation alone leaves the old value live in existing deployment
   artifacts until you redeploy.
5. **Assume the exposure window was fully used.** Plan for the worst case, not the
   likely one.

---

## 5. Project-specific rules

- **`.gitignore` blocks** `.env*`, `*.pem`, `*.key`, `**/service_role*`, keystores.
  Don't work around it.
- **CI secret scan** runs on every push (`.github/workflows/tests.yml`) and fails
  the build on GitHub PATs, `sb_secret_…` keys, and raw JWTs.
- **Every admin RPC must gate on `service_role`.** `admin_rollback_user()` shows
  the pattern:
  ```sql
  if current_setting('request.jwt.claims', true)::jsonb->>'role' <> 'service_role' then
    raise exception 'forbidden';
  end if;
  ```
- **Never log raw GPS tracks.** `04_ANTI_CHEAT.md` argues this on privacy grounds;
  it's also a breach-severity multiplier. The aggregates in `claim_events` are
  enough for forensics.
- **Never expose another user's track.** Only aggregate cell ownership is public.
  `get_cell_detail()` deliberately returns a *contender count*, not identities.
- **App signing keys** (`*.jks`, `*.keystore`) are unrecoverable if lost and
  catastrophic if stolen — an attacker can ship a malicious update under your
  identity. Back them up somewhere encrypted and offline, never in the repo.

---

## 6. Quick reference

| Credential | Commit it? | Paste to a third party? |
|---|---|---|
| `sb_publishable_…` | ✅ Yes | ✅ Fine |
| Mapbox public token | ✅ Yes (with URL restrictions) | ✅ Fine |
| Fine-grained PAT, 1 repo, short expiry | ❌ Never | ⚠️ Only if unavoidable — delete right after |
| Classic PAT / Vercel token | ❌ Never | ❌ No — scope it down first |
| `sb_secret_…` / `service_role` | ❌ Never | ❌ **Never, under any circumstances** |
| Android keystore / iOS signing cert | ❌ Never | ❌ Never |
