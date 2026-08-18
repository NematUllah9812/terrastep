# Terrastep — Issues Log

Every blocker hit during development, what caused it, and how it was fixed.
Written so the project can be picked up on a different machine, weeks later,
without rediscovering the same problems.

**Format:** each entry has Symptom → Cause → Fix → Prevention.
Newest phase last. `#` numbers are stable — reference them in commits.

**Legend:** 🔴 blocked work · 🟡 slowed work · 🟢 caught before it bit us

---

## Environment & Tooling

### #1 🟡 `node --check` fails on a process substitution
**Symptom**
```
Error: ENOENT: no such file or directory, open '/proc/1459/fd/pipe:[14935]'
```
when validating the prototype's inline JS via `node --check <(sed ... file.html)`.

**Cause** `node --check` reads the path twice (stat, then open). A process
substitution is a one-shot pipe — it's already drained by the second read.

**Fix** Write to a real temp file first.
```bash
sed -n '/^<script>/,/^<\/script>/p' prototype/index.html | sed '1d;$d' > /tmp/proto.js
node --check /tmp/proto.js
```

**Prevention** Any tool that seeks or re-opens its input (`node --check`,
`python -m py_compile`, most linters) needs a real file, not a pipe.

---

### #2 🟡 `apt-get install` fails without sudo, silently
**Symptom** Package install appeared to fail with no useful output; `psql` still
not found afterwards.

**Cause** The sandbox user isn't root, and the failure message was being
swallowed by output redirection.

**Fix** Fall through to `sudo`, and always surface the log tail on failure:
```bash
apt-get install -y postgresql >/tmp/apt.log 2>&1 \
  || sudo apt-get install -y postgresql >/tmp/apt.log 2>&1 \
  || tail -3 /tmp/apt.log
```

**Prevention** Never redirect an install to `/dev/null`. Log it and print the
tail on failure.

---

### #3 🔴 Installed packages don't survive between sessions
**Symptom** `./tests/run_tests.sh` worked, then later the same command gave
`initdb: command not found` with no changes made.

**Cause** The workspace snapshot persists files under `/home/user` but **not**
installed system packages, running processes, or shell state. Postgres was
simply gone.

**Fix** Reinstall (~10 s), then re-run. Nothing in the repo was wrong.

**Prevention** Treat the toolchain as ephemeral. `run_tests.sh` is written to be
run from scratch and now fails with an explicit install hint (see #10). If you
resume this project and tests won't run, **install Postgres first** before
debugging anything else.

---

### #4 🟡 Git identity lost between sessions
**Symptom**
```
Author identity unknown
fatal: empty ident name (for <user@e2b.local>) not allowed
```
mid-commit, despite having committed successfully earlier.

**Cause** Same as #3 — `git config` values written to `.git/config` were reset,
and `.git/config` is deliberately excluded from workspace snapshots (it can hold
credentials).

**Fix**
```bash
git config user.email "nematullah9812@users.noreply.github.com"
git config user.name  "NematUllah9812"
```

**Prevention** Expect to re-set identity and re-add the remote each session.
Cheap, but do it *before* a long commit message, not after.

---

## Database & Test Harness

### #5 🔴 Supabase-only extensions unavailable locally
**Symptom** `01_DATA_MODEL.sql` aborts on
`create extension postgis / pg_cron / h3` against vanilla Postgres.

**Cause** These ship with Supabase's managed image, not stock Postgres.

**Fix** `tests/run_tests.sh` strips those lines at load time with `sed`, and
`tests/00_shim.sql` supplies minimal stand-ins. **The committed SQL files are
never modified** — the shim exists only for local testing.
```bash
sed -e 's/^create extension if not exists postgis.*/-- shimmed/' \
    -e 's/^create extension if not exists pg_cron.*/-- shimmed/' \
    -e 's/^create extension if not exists h3.*/-- shimmed/' \
    01_DATA_MODEL.sql | psql -d terrastep -f -
```

**Prevention** Keep production SQL authoritative; adapt in the harness. If the
harness and production diverge, production wins.

⚠️ **Still to verify on real Supabase:** whether the `h3` extension is available
in your region (`select * from pg_available_extensions where name like 'h3%'`).
If yes, uncomment the `[H3-PG]` blocks in `02_CLAIM_ENGINE.sql` — they close the
telemetry-replay hole.

---

### #6 🔴 `auth.uid()` and `realtime.send()` don't exist outside Supabase
**Symptom** `claim_cells()` fails to create — unknown schema `auth` / `realtime`.

**Cause** Supabase-provided. `auth.uid()` reads the caller's JWT.

**Fix** `tests/00_shim.sql` defines both. `auth.uid()` reads a session GUC so
tests can switch users:
```sql
create function auth.uid() returns uuid language sql stable as $$
  select nullif(current_setting('test.uid', true), '')::uuid;
$$;
```
```sql
-- in a test, become Alice:
select set_config('test.uid','1111...1111', false);
```
`realtime.send()` becomes a `raise notice`, which doubles as a useful trace of
what *would* have been broadcast.

**Prevention** Good side effect: the engine is now testable without any network
or Supabase account. Keep it that way.

⚠️ **Untested in reality:** whether `realtime.send()` behaves the same inside a
`SECURITY DEFINER` function on real Supabase. Verify at threshold 3.2.

---

### #7 🟡 PostGIS `geography` type unavailable
**Symptom** `territories.center geography(Point, 4326)` — type does not exist.

**Cause** No PostGIS locally.

**Fix** Shim `create domain geography as text;` plus a fake `st_point()`, and the
harness rewrites the column type and strips `::geography` casts. The column is
only a centroid for optional clustering — no query in the engine depends on real
spatial operations, which is why this substitution is safe.

**Prevention** Deliberate design choice: **distance maths uses `haversine_m()`,
not PostGIS.** Keeps the engine portable and avoids a hard dependency for one
convenience column.

---

### #8 🟢 Test expectation wrong: validation rules are order-dependent
**Symptom**
```
FAIL A2 shake attack (2000 steps, 5m)
  got=below_min_distance  want=steps_without_distance
```

**Cause** **The engine was right; the test was wrong.** `validate_cell_claim()`
checks the minimum-distance floor (R2) *before* the step/distance ratio rule
(R6). A 5 m "walk" trips the floor first and never reaches the ratio check.

**Fix** Split into two tests that reflect real attacker behaviour:
- **A2a** crude shake (2000 steps, 5 m) → `below_min_distance`
- **A2b** *smart* shake — walks 90 m to clear the floor, then shakes for steps
  (2000 steps, 90 m) → `steps_without_distance`

A2b is the more valuable test: it proves R6 catches an attacker who has already
defeated the simple floors.

**Prevention** When a rejection test fails with a *different* rejection reason,
suspect the test before the code. Assert the specific reason, never just
"was rejected" — otherwise a rule can silently stop working while tests stay
green because an earlier rule masks it.

---

### #9 🟢 Test fixture violated its own time window
**Symptom** A2b returned `dwell_exceeds_window` instead of the expected reason.

**Cause** The fixture claimed 600 s of dwell inside a default 9-minute (540 s)
window. Rule R5 correctly rejected it — a genuine catch of a bad fixture.

**Fix** Lowered fixture dwell to 500 s.

**Prevention** Test fixtures must themselves be internally coherent. R5 exists
precisely to catch dwell > wall-clock, and it caught it here — in a test.

---

### #10 🔴 `run_tests.sh` unusable after clone
**Symptom** `./tests/run_tests.sh` → `Permission denied`.

**Cause** `chmod +x` in the working tree does **not** stage a mode change. The
first commit stored the file as `100644`.

**Fix**
```bash
chmod +x tests/run_tests.sh
git update-index --chmod=+x tests/run_tests.sh
```
Index now shows `100755`.

**Prevention** After adding any script, check `git ls-files -s path` shows
`100755` before pushing. Or invoke as `bash tests/run_tests.sh` to sidestep it.

---

### #11 🟡 Postgres binary discovery too narrow
**Symptom** After reinstall, `initdb: command not found` — the script's own
`PATH` setup wasn't finding it.

**Cause** Detection only looked at `/usr/lib/postgresql/*/bin` (Debian layout)
and failed silently, then hit a bare not-found error with no guidance.

**Fix** Search Debian, Homebrew (Intel + Apple Silicon) and Postgres.app, honour
an explicit `PGBIN` override, and exit with install instructions:
```
ERROR: Postgres client tools not found (initdb).
  Debian/Ubuntu : sudo apt-get install -y postgresql
  macOS         : brew install postgresql@17
  Or set PGBIN=/path/to/postgres/bin
```

**Prevention** Any script depending on an external binary should fail with the
fix, not just the symptom.

---

### #16 🔴 `run_tests.sh` not re-runnable — orphaned postmaster holds the port
**Symptom** Second invocation fails:
```
pg_ctl: could not start server
FATAL: could not create any TCP/IP sockets
LOG: could not bind IPv4 address "127.0.0.1": Address already in use
```

**Cause** Three compounding bugs, found by *testing the documented resume
procedure* rather than assuming it worked:
1. The script never stopped the server it started, so a postmaster from the
   previous run kept holding port 5433.
2. Deleting `PGDATA` orphaned that process — no pid file, so `pg_ctl status`
   reported "not running" while the port stayed bound.
3. The port was hardcoded, so there was no fallback.

Also masked by `pg_ctl ... >/dev/null` swallowing the real error.

**Fix** Four changes:
- Stop any prior server before starting (`pg_ctl -m immediate stop || true`)
- `trap cleanup EXIT` so the server always shuts down
- Probe 5433–5460 for a free port instead of assuming one
- On failure, print the Postgres log tail instead of a bare error
- Validate `PGDATA` with `PG_VERSION`, not just directory existence

**Verified** Three consecutive runs — with an orphan running, immediately again,
and after deleting `PGDATA` — all 48 passing.

**Prevention** **A "run this to get started" command must be idempotent.** Test
it twice in a row, and once after deleting its state. This bug only surfaced
because the documented resume steps were actually executed.

---

## Security & Git

### #12 🟢 CI secret scanner would have failed on its own documentation
**Symptom** Pre-commit scan flagged 6 hits in `SECURITY.md` and
`CURRENT_PROGRESS.md` — all prose *describing* key formats, no real secrets.

**Cause** The regex matched `sb_secret_` as a bare prefix with only `{20,}`
trailing characters, so documentation naming the prefix matched.

**Fix** Anchor patterns to a full-length run of key characters and exclude the
docs file:
```
ghp_[A-Za-z0-9]{36}|github_pat_[A-Za-z0-9_]{50,}|sb_secret_[A-Za-z0-9_-]{28,}|eyJhbGciOi[A-Za-z0-9_-]{30,}
```
Verified both directions: 3 real-shaped secrets caught, 0 false positives on
prose. Docs also use a Unicode ellipsis (`sb_secret_…`) after prefixes, which
cannot match an ASCII character class.

**Prevention** **Always test a scanner against both true and false positives.**
A scanner that cries wolf gets disabled within a week, which is worse than no
scanner. Caught before the first CI run.

---

### #13 🔴 A credential was pasted into chat
**Symptom** A classic GitHub PAT with full `repo` scope was shared in
conversation to enable a push.

**Cause** Convenience — no laptop access, and a repo needed creating.

**Impact** `repo` scope grants read/write to **every** repository on the account,
not just the intended one. The token also passed through chat transport,
provider logs and conversation history.

**Fix**
1. Token used without ever writing it to a file; every commit was
   secret-scanned first.
2. Pushed via `http.extraheader` so it never entered `.git/config`:
   ```bash
   AUTH=$(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)
   git -c http.extraheader="Authorization: Basic $AUTH" push origin main
   ```
   Stored remote stays clean: `https://github.com/NematUllah9812/terrastep.git`
3. Token deleted immediately after.
4. Replaced with a fine-grained PAT: **1 repo, Contents + Metadata + Workflows,
   7-day expiry.**

**Prevention** See `SECURITY.md`. Short version: prefer `gh auth login` so no
secret is ever transmitted; if delegation is unavoidable, use a fine-grained
token scoped to one repo and delete it the moment the push lands.

⚠️ **Deleting a token stops future use — it does not undo past use.** After any
exposure, audit for unexpected commits, deploy keys, altered workflows and newly
minted tokens.

---

### #14 🟡 Fine-grained tokens cannot create repositories
**Symptom** Not hit — anticipated while planning the switch away from the
classic PAT.

**Cause** A fine-grained token's repository picker only lists repos that
**already exist**. Creation is an account-level action a repo-scoped token
deliberately can't perform. The original repo was created with the classic
token's `repo` scope.

**Fix** Reorder the workflow:
1. Create the empty private repo in the **GitHub mobile app**
2. *Then* generate a fine-grained token scoped to it
3. Delegate the push, delete the token

**Prevention** Better anyway — repo creation stays under your control, and the
token can never create anything new.

---

### #15 🟡 Workflow files need a separate permission
**Symptom** Anticipated. A push containing `.github/workflows/*.yml` with a
Contents-only token fails:
```
refusing to allow a Personal Access Token to create or update workflow
`.github/workflows/tests.yml` without `workflow` scope
```

**Cause** Contents: write does **not** cover workflow files. Writing a workflow
means executing arbitrary code in CI, so GitHub gates it separately.

**Fix** Enable **Workflows: Read and write** on the token for that commit only,
then revert to Contents-only for routine pushes.

**Prevention** Confusing error — it looks like a file-write problem, but it's a
scope problem. Noted in `SECURITY.md §3`.

---

## Client (Flutter / Dart)

### #17 🔴 Stationary GPS jitter accumulated 1.1 km of phantom distance
**Symptom** Threshold 1.6 test T5 failed on first run:
```
FAIL T5 GPS jitter while stationary
  Expected: < 900    Actual: 1144.14
```
A phone standing still with 28 m GPS accuracy accrued **1,144 m over five
minutes** — enough to claim a cell without leaving the room. Threshold 4.2
specifies *"stand still indoors 10 min → distance < 20 m"*.

**Cause** The accumulator summed the raw distance between consecutive fixes,
gated only on `d > 1.0 m`. A stationary phone produces a **random walk**: each
fix lands tens of metres from the last. Summing those hops integrates noise into
kilometres.

**Failed first attempt.** An accuracy-aware deadband (subtract a noise floor
from each hop) does *not* work. Measured across noise factors:

| factor | real walk | jitter |
|---|---|---|
| 0.00 | 456 m | 1267 m |
| 0.25 | 376 m | 816 m |
| 0.50 | 105 m | 397 m |
| 0.75 | **0 m** | 138 m |

At 28 m accuracy the individual jitter hops are genuinely large, so any deadband
big enough to suppress them also erases real walking. There is no good value.

**Fix — displacement anchor.** The distinguishing property isn't hop size, it's
**net displacement**: jitter oscillates around a point, walking moves away from
it. So hold an anchor fix and only credit distance once the current fix is
`2 × accuracy` away, then move the anchor there.

```dart
final threshold = math.max(8.0, math.max(anchor.accuracy, fix.accuracy) * 2.0);
if (d < threshold) return 0;      // never escaped the noise envelope
_anchor = fix;
return d;
```

`2.0` was chosen by measurement (`app/tool/tune.dart`), being the smallest factor
that zeroes jitter while leaving a walk fully credited.

**Verified** (`app/tool/verify.dart`):

| Scenario | Credited | Claimable |
|---|---|---|
| Genuine 10-min walk (810 m actual) | **789 m (97%)** | 4 cells ✅ |
| Standing still, 28 m accuracy, 10 min | **0.0 m** | 0 ✅ |
| Shaking phone, 3025 fake steps | **0.0 m** | 0 ✅ |

**Prevention** Two lessons. First, **write the adversarial test before the
implementation** — T5 existed because the plan demanded it, and it caught a
cell-claiming exploit on the very first run. Second, when a filter can't
separate two signals, **look for a different discriminating property** rather
than tuning the parameter; hop magnitude was the wrong axis, net displacement
was the right one.

---

### #18 🟡 A too-aggressive fix broke the golden path
**Symptom** After the first anti-drift attempt, T5 passed but the golden-path
test failed: a genuine 8-minute walk became unclaimable (`readyToSubmit()` empty).

**Cause** The 0.75 noise factor suppressed jitter by erasing *all* movement.
Tests only caught it because a "real walk must still work" test existed
alongside the adversarial ones.

**Fix** Replaced with the anchor filter (#17), which passes both.

**Prevention** **Every anti-cheat test needs a paired golden-path test.** A
filter that rejects everything scores 100% against attackers and ships a broken
product. This is the client-side mirror of the SQL suite's `A1 valid walk
accepted`.

---

### #19 🔴 Rate limiting backed off one batch instead of the queue
**Symptom** Sync test failure:
```
FAIL rate limiting backs off the whole queue
  Expected: <1>   Actual: <2>
```
The worker made a second network call immediately after the server had said
`rate_limited`.

**Cause** On a rate-limit response the worker called
`outbox.recordFailure(entry.batchUuid, ...)`, which delays **only that batch**.
`break` stopped the current round, but the next flush (90 s later) found the
*next* batch due and sent it — still inside the server's cooldown.

Real-world consequence, from `02_CLAIM_ENGINE.sql`: every rate-limited call adds
**+5 suspicion**. A user who walked a lot and tripped the 50-cells/hour limit
would keep hammering, and could shadow-ban themselves for walking too much.

**Fix** Added `Outbox.backoffAll(error, notBefore)` and used it for
**account-wide** conditions (rate limiting, expired auth, offline) as opposed to
batch-specific ones. Two deliberate details:

- **`attempts` is not incremented.** The batch didn't fail — the account was
  throttled. Counting it would push healthy batches toward the poison
  threshold and silently discard walked data.
- **Auth failures use it too.** An expired JWT invalidates every batch, so
  retrying the rest is pointless.

**Prevention** **Classify a failure before reacting to it.** Ask "is this the
batch's fault, or the account's?" Batch-specific → back off that batch and count
the attempt. Account-wide → hold everything and count nothing. Two regression
tests now pin this: one asserts all four queued batches are held, the other that
`attempts` stays 0.

---

## Open Items

Known problems not yet solved. Carry these forward.

| # | Item | Where | Status |
|---|---|---|---|
| O1 | `h3` extension availability on Supabase unverified | #5 | Check at threshold 2.1 |
| O2 | `realtime.send()` inside `SECURITY DEFINER` untested on real Supabase | #6 | Verify at threshold 3.2 |
| O3 | Rate limiting written but untested | 4.6 | Needs a 60-cell fixture |
| O4 | `score_suspicion()` written, never deployed or run | 4.7 | Needs a synthetic bot profile |
| O5 | `admin_rollback_user()` untested | 4.8 | Needs a reassignment fixture |
| O6 | RLS hostile test not written | 2.4 | Needs a real JWT — can't be shimmed |
| O7 | Background battery drain unmeasured | 0.3 | **Highest project risk** |

---

## Recurring Patterns

Four lessons that keep resurfacing:

1. **The sandbox is ephemeral; the repo is not.** Packages, processes, git
   identity and remotes all reset (#3, #4). Anything that must survive goes in a
   committed file. On resuming: install Postgres, set git identity, re-add the
   remote.

2. **When a test fails, suspect the test first.** Both engine "failures" (#8, #9)
   were wrong expectations. The engine was correct each time.

3. **Assert the specific reason, not just failure.** #8 only surfaced because
   tests assert exact rejection strings. `assert rejected` would have hidden a
   masked rule.

4. **Test the safety net itself.** The secret scanner (#12) would have broken
   every CI run. Tools that protect you need their own tests, in both directions.
